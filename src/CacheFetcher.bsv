import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;

//TODO: move common typedefs out of this file
import DRAMModel::*;

typedef struct {
  RAddr ra;
  CAddr ca; 
  BAddr ba;
  Bit#(1) cacheSel;
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
  //TODO these can be eliminated with some thought. 
  Vector#(dep, Vector#(w, FIFO#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) aBuf <- replicateM(replicateM(mkFIFO()));
  Vector#(dep, Vector#(h, FIFO#(Tuple2#(Bit#(TLog#(cache_dep)), dType)))) bBuf <- replicateM(replicateM(mkFIFO()));

  //ask dram for data
  //get data from dram, break it up
  //issue a or b cache write request
  let r = reqQ.first;
  rule handleReq if (dram.init_done); 
    dram.request(r.ra, r.ca, r.ba, 0, ?);
  endrule

  rule getDramData; 
    Bit#(512) data <- dram.read_data();
    Vector#(dep, dType) dataWords = unpack(data);
    for (Integer d=0; d<valueOf(dep); d=d+1) begin
      if (r.cacheSel==0) begin
        aBuf[d][r.cacheBa].enq( tuple2(r.cacheDa, dataWords[d]) );
      end
      else begin
        bBuf[d][r.cacheBa].enq( tuple2(r.cacheDa, dataWords[d]) );
      end
    end
    reqQ.deq;
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


module mkTop();
  DRAMUser dram <- mkDRAMModel();
  CacheFetch#(4, 8, 16, 1024, UInt#(32)) cf <- mkCacheFetcher(dram);
endmodule
  
