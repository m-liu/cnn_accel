import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;
import Cu::*;
import CacheFetcher::*;
import Writeback::*;
import DRAMModel::*;


interface CUArray#(numeric type w, numeric type h, numeric type dep, numeric type cache_dep, type dType);
  interface Put#(CacheFetchReq#(w, h, cache_dep)) cacheReq;
  interface Put#(WBReq#(w)) wbReq;
  interface Vector#(dep, Vector#(w, Put#(Tuple2#(Bit#(TLog#(w)), Bit#(TLog#(cache_dep)))))) aCacheReadReq;
  interface Vector#(dep, Vector#(h, Put#(Bit#(TLog#(cache_dep))))) bCacheReadReq;
  interface Vector#(dep, Vector#(h, Put#(OpCode))) peOp;
endinterface


//Depth (or number of CUs) should always be 16 for 32-bit types or 32 for
//16-bit types to match DDR interface and/or DDR burst len
module mkCuArray#(DRAMUser dramIn, DRAMUser dramOut)
                      (CUArray#(ARR_W, ARR_H, ARR_D, CACHE_DEP, DTYPE));

  CacheFetch#(ARR_W, ARR_H, ARR_D, CACHE_DEP, DTYPE) cacheFetch <- mkCacheFetcher(dramIn);
  Vector#(ARR_D, CU#(ARR_W, ARR_H, CACHE_DEP, DTYPE)) cuArr <- replicateM(mkCU());
  WriteBack#(ARR_W, ARR_D, DTYPE) wb <- mkWriteBack(dramOut);
  
  //connect cache fetcher and write back modules with cuArray
  for (Integer d=0; d<valueOf(ARR_D); d=d+1) begin
    mkConnection(cacheFetch.aCacheWrite[d], cuArr[d].aCacheWrite);
    mkConnection(cacheFetch.bCacheWrite[d], cuArr[d].bCacheWrite);
    mkConnection(wb.cCacheRead[d], cuArr[d].cCacheRead);
  end

  Vector#(ARR_D, Vector#(ARR_W, Put#(Tuple2#(Bit#(TLog#(ARR_W)), Bit#(TLog#(CACHE_DEP)))))) aVec = newVector();
  Vector#(ARR_D, Vector#(ARR_H, Put#(Bit#(TLog#(CACHE_DEP))))) bVec = newVector();
  Vector#(ARR_D, Vector#(ARR_H, Put#(OpCode))) peVec = newVector();
  for (Integer di=0; di<valueOf(ARR_D); di=di+1) begin
    aVec[di] = cuArr[di].aCacheReadReq;
    bVec[di] = cuArr[di].bCacheReadReq;
    peVec[di] = cuArr[di].peOp;
  end
  
  interface cacheReq = cacheFetch.req;
  interface wbReq = wb.wbReq;
  interface aCacheReadReq = aVec;
  interface bCacheReadReq = bVec;
  interface peOp = peVec;

endmodule


//================================
// Instantiate for testing
//================================
module mkTop();
  DRAMUser dramIn <- mkDRAMModel();
  DRAMUser dramOut <- mkDRAMModel();
  CUArray#(ARR_W, ARR_H, ARR_D, CACHE_DEP, DTYPE) cuArr <- mkCuArray(dramIn, dramOut);
endmodule



