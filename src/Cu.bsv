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
/*
typedef 4 PE_W; 
typedef 16 PE_H;
typedef 16 PE_D;
typedef 1024 CACHE_DEP;
typedef UInt#(32) DType;
*/

interface CU#(numeric type w, numeric type h, numeric type cache_dep, type dType);
  //aCache writes and read requests
  interface Vector#(w, Put#(Tuple2#(Bit#(TLog#(cache_dep)), dType))) aCacheWrite;
  interface Vector#(w, Put#(Tuple2#(Bit#(TLog#(w)), Bit#(TLog#(cache_dep))))) aCacheReadReq;
  //bCache writes and read requests
  interface Vector#(h, Put#(Tuple2#(Bit#(TLog#(cache_dep)), dType))) bCacheWrite;
  interface Vector#(h, Put#(Bit#(TLog#(cache_dep)))) bCacheReadReq;
  //cCache read data
  interface Vector#(w, Get#(dType)) cCacheRead;

  //PE control signals for each row
  interface Vector#(h, Put#(OpCode)) peOp;
endinterface


//FIXME: we use an output FIFO here, but its possible for results from diff rows of PEs
// to be out of order. Especially if the # of MACs is small (e.g. <16). 
// The true fix should be a completion buffer. Using a FIFO for convenience for now. 

module mkCU(CU#(w, h, cache_dep, dType))
  provisos( Arith#(dType),
            Bits#(dType, a__) );


  BankedCache#(w, cache_dep, Bit#(TLog#(w)), Bit#(TLog#(cache_dep)), dType) aCache <- mkBankedBRAMCache();
  VectorCache#(h, cache_dep, Bit#(TLog#(cache_dep)), dType) bCache <- mkVectorBRAMCache();
  //TODO: this may be too deep
  //TODO: this probably should be a completion buffer
  //VectorCache#(w, cache_dep, Bit#(TLog#(cache_dep)), dType) cCache <- mkVectorBRAMCache(); //out
  Vector#(w, FIFO#(dType)) outQ <- replicateM(mkSizedFIFO(valueOf(cache_dep))); 
  PEArr#(w, h, dType) peArr <- mkPEArray();
  
  //Connect input caches datapath to PE
  mkConnection(peArr.vA, aCache.readResp);
  mkConnection(peArr.vB, bCache.readResp);
  
  //Connect PE to output cache
  for (Integer i=0; i<valueOf(w); i=i+1) begin
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
