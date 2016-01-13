import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;
import CacheBanked::*;
import CacheVector::*;
import Pe::*;

interface CU#(numeric type w, numeric type h, numeric type cache_dep, type dType);
  interface Vector#(w, Put#(Tuple2#(Bit#(TLog#(cache_dep)), dType))) aCacheWrite;
  interface Vector#(w, Put#(Tuple2#(Bit#(TLog#(w)), Bit#(TLog#(cache_dep))))) aCacheReadReq;
  interface Vector#(h, Put#(Tuple2#(Bit#(TLog#(cache_dep)), dType))) bCacheWrite;
  interface Vector#(h, Put#(Bit#(TLog#(cache_dep)))) bCacheReadReq;
  interface Vector#(w, Get#(dType)) cCacheRead;
  //PE control signals for each row
  interface Vector#(h, Put#(OpCode)) peOp;
endinterface

//============================================================================
// Synthesizable compute unit (CU)
// Each CU is a 2D array of PEs with 2 input caches and an output cache
//============================================================================

//FIXME: we use an output FIFO here, but its possible for results from diff rows of PEs
// to be out of order. Especially if the # of MACs is small (e.g. <16). 
// The true fix should be a completion buffer. Using a FIFO for convenience for now. 

(*synthesize*)
module mkCU(CU#(ARR_W, ARR_H, CACHE_DEP, DTYPE));

  BankedCache#(ARR_W, CACHE_DEP, Bit#(TLog#(ARR_W)), Bit#(TLog#(CACHE_DEP)), DTYPE) aCache <- mkBankedBRAMCacheSynth();
  VectorCache#(ARR_H, CACHE_DEP, Bit#(TLog#(CACHE_DEP)), DTYPE) bCache <- mkVectorBRAMCacheSynth();
  //TODO: too deep; use a completion buffer?
  //VectorCache#(w, cache_dep, Bit#(TLog#(cache_dep)), dType) cCache <- mkVectorBRAMCache(); //out
  Vector#(ARR_W, FIFO#(DTYPE)) outQ <- replicateM(mkSizedFIFO(valueOf(CACHE_DEP))); 
  PEArr#(ARR_W, ARR_H, DTYPE) peArr <- mkPEArray();
  
  //Connect input caches datapath to PE
  mkConnection(peArr.vA, aCache.readResp);
  mkConnection(peArr.vB, bCache.readResp);
  
  //Connect PE to output cache
  for (Integer i=0; i<valueOf(ARR_W); i=i+1) begin
    rule peOut;
      let d <- peArr.vRes[i].get();
      outQ[i].enq(d);
    endrule
  end

  interface aCacheWrite = aCache.writeReq;
  interface aCacheReadReq = aCache.readReq;
  interface bCacheWrite = bCache.writeReq;
  interface bCacheReadReq = bCache.readReq;
  interface cCacheRead = map(toGet, outQ);
  interface peOp = peArr.vOp;

endmodule


//================================
// Instantiate for testing
//================================
module mkTop();
  Vector#(ARR_D, CU#(ARR_W, ARR_H, CACHE_DEP, DTYPE)) cuArr <- replicateM(mkCU());
endmodule





/*
(*synthesize*)
module mkCuSynth(CU#(ARR_W, ARR_H, CACHE_DEP, DTYPE));
  CU#(ARR_W, ARR_H, CACHE_DEP, DTYPE) cu <- mkCU();
  return cu;
endmodule
*/

