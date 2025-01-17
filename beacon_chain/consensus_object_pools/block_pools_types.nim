# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Standard library
  std/[deques, strformat, tables, hashes],
  # Status libraries
  stew/[endians2, byteutils], chronicles,
  eth/keys,
  # Internals
  ../spec/[datatypes, crypto, digest, signatures_batch],
  ../beacon_chain_db, ../extras

from libp2p/protocols/pubsub/pubsub import ValidationResult
export ValidationResult

# #############################################
#
#            Quarantine & DAG
#
# #############################################
#
# The Quarantine and DagChain data structures
# keep track respectively of unsafe blocks coming from the network
# and blocks that underwent verification and have a resolved path to
# the last finalized block known.

type
  BlockError* = enum
    MissingParent ##\
      ## We don't know the parent of this block so we can't tell if it's valid
      ## or not - it'll go into the quarantine and be reexamined when the parent
      ## appears or be discarded if finality obsoletes it

    Unviable ##\
      ## Block is from a different history / fork than the one we're interested
      ## in (based on our finalized checkpoint)

    Invalid ##\
      ## Block is broken / doesn't apply cleanly - whoever sent it is fishy (or
      ## we're buggy)
    Old
    Duplicate

  QuarantineRef* = ref object
    ## Keeps track of unsafe blocks coming from the network
    ## and that cannot be added to the chain
    ##
    ## This only stores valid blocks that cannot be linked to the
    ## ChainDAGRef DAG due to missing ancestor(s).
    ##
    ## Invalid blocks are dropped immediately.

    orphans*: Table[(Eth2Digest, ValidatorSig), SignedBeaconBlock] ##\
    ## Blocks that have passed validation but that we lack a link back to tail
    ## for - when we receive a "missing link", we can use this data to build
    ## an entire branch

    missing*: Table[Eth2Digest, MissingBlock] ##\
    ## Roots of blocks that we would like to have (either parent_root of
    ## unresolved blocks or block roots of attestations)

    sigVerifCache*: BatchedBLSVerifierCache ##\
    ## A cache for batch BLS signature verification contexts
    rng*: ref BrHmacDrbgContext  ##\
    ## A reference to the Nimbus application-wide RNG

    inAdd*: bool

  MissingBlock* = object
    tries*: int

  FetchRecord* = object
    root*: Eth2Digest

  ChainDAGRef* = ref object
    ## Pool of blocks responsible for keeping a DAG of resolved blocks.
    ##
    ## It is responsible for the following
    ##
    ## - Handle requests and updates to the "ColdDB" which
    ##   holds the canonical chain.
    ## - Maintain a direct acyclic graph (DAG) of
    ##   candidate chains from the last
    ##   finalized block.
    ##
    ## When a chain becomes finalized, it is saved in the ColdDB,
    ## the rejected candidates are discarded and this pool
    ## is pruned, only keeping the last finalized block.
    ##
    ## The last finalized block is called the tail block.

    # -----------------------------------
    # ColdDB - Canonical chain

    db*: BeaconChainDB ##\
      ## ColdDB - Stores the canonical chain

    # -----------------------------------
    # ChainDAGRef - DAG of candidate chains

    blocks*: Table[Eth2Digest, BlockRef] ##\
    ## Directed acyclic graph of blocks pointing back to a finalized block on the chain we're
    ## interested in - we call that block the tail

    genesis*: BlockRef ##\
    ## The genesis block of the network

    tail*: BlockRef ##\
    ## The earliest finalized block we know about

    heads*: seq[BlockRef] ##\
    ## Candidate heads of candidate chains

    finalizedHead*: BlockSlot ##\
    ## The latest block that was finalized according to the block in head
    ## Ancestors of this block are guaranteed to have 1 child only.

    # -----------------------------------
    # Rewinder - Mutable state processing

    headState*: StateData ##\
    ## State given by the head block - must only be updated in `updateHead` -
    ## always matches dag.head

    epochRefState*: StateData ##\
      ## State used to produce epochRef instances - must only be used in
      ## `getEpochRef`

    clearanceState*: StateData ##\
      ## Cached state used during block clearance - must only be used in
      ## clearance module

    tmpState*: StateData ## Scratchpad - may be any state

    updateFlags*: UpdateFlags

    runtimePreset*: RuntimePreset

  EpochRef* = ref object
    epoch*: Epoch
    current_justified_checkpoint*: Checkpoint
    finalized_checkpoint*: Checkpoint
    eth1_data*: Eth1Data
    eth1_deposit_index*: uint64
    beacon_proposers*: array[
      SLOTS_PER_EPOCH, Option[(ValidatorIndex, ValidatorPubKey)]]
    shuffled_active_validator_indices*: seq[ValidatorIndex]
    # This is an expensive cache that is sometimes shared among epochref
    # instances - in particular, validators keep their keys and locations in the
    # validator list in each particular history.
    validator_key_store*: (Eth2Digest, ref seq[ValidatorPubKey])

    # balances, as used in fork choice
    effective_balances_bytes*: seq[byte]

  BlockRef* = ref object
    ## Node in object graph guaranteed to lead back to tail block, and to have
    ## a corresponding entry in database.
    ## Block graph should form a tree - in particular, there are no cycles.

    root*: Eth2Digest ##\
    ## Root that can be used to retrieve block data from database

    parent*: BlockRef ##\
    ## Not nil, except for the tail

    slot*: Slot # could calculate this by walking to root, but..

    epochRefs*: seq[EpochRef] ##\
    ## Cached information about the epochs starting at this block.
    ## Could be multiple, since blocks could skip slots, but usually, not many
    ## Even if competing forks happen later during this epoch, potential empty
    ## slots beforehand must all be from this fork. find/getEpochRef() are the
    ## only supported way of accesssing these.
    ## In particular, epoch refs are only stored with the last block of the
    ## parent epoch - this way, it's easy to find them from any block in the
    ## epoch - including when there are forks that skip the epoch slot.

  BlockData* = object
    ## Body and graph in one

    data*: TrustedSignedBeaconBlock # We trust all blocks we have a ref for
    refs*: BlockRef

  StateData* = object
    data*: HashedBeaconState

    blck*: BlockRef ##\
    ## The block associated with the state found in data

  BlockSlot* = object
    ## Unique identifier for a particular fork and time in the block chain -
    ## normally, there's a block for every slot, but in the case a block is not
    ## produced, the chain progresses anyway, producing a new state for every
    ## slot.
    blck*: BlockRef
    slot*: Slot ##\
      ## Slot time for this BlockSlot which may differ from blck.slot when time
      ## has advanced without blocks

  OnBlockAdded* = proc(
    blckRef: BlockRef, blck: TrustedSignedBeaconBlock,
    epochRef: EpochRef, state: HashedBeaconState) {.raises: [Defect], gcsafe.}
    # The `{.gcsafe.}` annotation is needed to shut up the compiler.

template validator_keys*(e: EpochRef): untyped = e.validator_key_store[1][]

template head*(v: ChainDagRef): BlockRef = v.headState.blck

func shortLog*(v: BlockSlot): string =
  try:
    if v.blck.isNil():
      &"nil:0@{v.slot}"
    elif v.blck.slot == v.slot:
      &"{v.blck.root.data.toOpenArray(0, 3).toHex()}:{v.blck.slot}"
    else: # There was a gap - log it
      &"{v.blck.root.data.toOpenArray(0, 3).toHex()}:{v.blck.slot}@{v.slot}"
  except ValueError as err:
    err.msg # Shouldn't happen - but also shouldn't crash!

func shortLog*(v: BlockRef): string =
  try:
    if v.isNil():
      "BlockRef(nil)"
    else:
      &"{v.root.data.toOpenArray(0, 3).toHex()}:{v.slot}"
  except ValueError as err:
    err.msg # Shouldn't happen - but also shouldn't crash!

func shortLog*(v: EpochRef): string =
  try:
    if v.isNil():
      "EpochRef(nil)"
    else:
      &"(epoch ref: {v.epoch})"
  except ValueError as err:
    err.msg # Shouldn't happen - but also shouldn't crash!

chronicles.formatIt BlockSlot: shortLog(it)
chronicles.formatIt BlockRef: shortLog(it)

func hash*(blockRef: BlockRef): Hash =
  hash(blockRef.root)
