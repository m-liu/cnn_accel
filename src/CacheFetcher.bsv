import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;
import DRAMModel::*;

typedef struct {
  DRAMAddr dramAddr; 
  Bit#(1) cacheSel; //0 is input cache, 1 is side cache
  Bit#(TLog#(TMax#(w, h))) cacheBa;
  Bit#(TLog#(cache_dep)) cacheDa;
} CacheFetchReq#(numeric type w, numeric type h, numeric type cache_dep) deriving (Bits, Eq);

interface CacheFetch#(numeric type w, numeric type h, numeric type dep, numeric type cache_dep, type dType);
  interface Vector#(dep, Vector#(w, Get#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) aCacheWrite;
  interface Vector#(dep, Vector#(h, Get#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) bCacheWrite;
  interface Put#(CacheFetchReq#(w, h, cache_dep)) req;
endinterface

//DRAM interface passed in as a param 
module mkCacheFetcher#(DRAMUser dram)(CacheFetch#(w,  h,  dep,  cache_dep, dType))
  provisos (  Bits#(dType, a__),
              Mul#(dep, a__, 512) );

  FIFO#(CacheFetchReq#(w, h, cache_dep)) reqQ <- mkFIFO();
  //TODO: this size is important, should match DRAM controller queue depth
  FIFO#(CacheFetchReq#(w, h, cache_dep)) inflightQ <- mkSizedFIFO(32); 
  //TODO these can be eliminated with some thought. 
  Vector#(dep, Vector#(w, FIFO#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) aBuf <- replicateM(replicateM(mkFIFO()));
  Vector#(dep, Vector#(h, FIFO#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) bBuf <- replicateM(replicateM(mkFIFO()));

  //ask dram for data
  //get data from dram, break it up
  //issue a or b cache write request
  rule handleReq if (dram.init_done); 
    let r = reqQ.first;
    dram.request(r.dramAddr.ra, r.dramAddr.ca, r.dramAddr.ba, 0, ?);
    inflightQ.enq(r);
    reqQ.deq;
  endrule

  rule getDramData; 
    let ri = inflightQ.first;
    Bit#(512) data <- dram.read_data();
    Vector#(dep, dType) dataWords = unpack(data);
    for (Integer d=0; d<valueOf(dep); d=d+1) begin
      if (ri.cacheSel==0) begin
        aBuf[d][ri.cacheBa].enq( tuple2(ri.cacheDa, dataWords[d]) );
      end
      else begin
        bBuf[d][ri.cacheBa].enq( tuple2(ri.cacheDa, dataWords[d]) );
      end
    end
    inflightQ.deq;
  endrule

  Vector#(dep, Vector#(w, Get#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) aVec = newVector();
  Vector#(dep, Vector#(h, Get#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) bVec = newVector();
  for (Integer d=0; d<valueOf(dep); d=d+1) begin
    aVec[d] = map(toGet, aBuf[d]);
    bVec[d] = map(toGet, bBuf[d]);
  end

  interface Put req = toPut(reqQ);
  interface aCacheWrite = aVec;
  interface bCacheWrite = bVec;

endmodule


//================================
// Instantiate for testing
//================================
module mkTop();
  DRAMUser dram <- mkDRAMModel();
  CacheFetch#(ARR_W, ARR_H, ARR_D, CACHE_DEP, DTYPE) cf <- mkCacheFetcher(dram);
endmodule
  
