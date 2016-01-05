import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;

// Simply a vector of BRAM banks/caches. Read/Write ports can only address one bank. 

interface VectorCache#(numeric type banks, numeric type depth, type rAddr, type dType);
  interface Vector#(banks, Put#(rAddr)) readReq;
  interface Vector#(banks, Get#(dType)) readResp;
  interface Vector#(banks, Put#(Tuple2#(rAddr, dType))) writeReq;
endinterface


module mkVectorBRAMCache(VectorCache#(banks, depth, rAddr, dType))
  provisos (Bits#(dType, a_),
            Bits#(rAddr, rsz),
            Log#(depth, rsz));

  BRAM_Configure cfg = defaultValue;
  cfg.memorySize = valueOf(depth);
  Vector#(banks, BRAM2Port#(rAddr, dType)) rams <- replicateM(mkBRAM2Server(cfg));


  Vector#(banks, Put#(rAddr)) readReqVec = newVector();
  Vector#(banks, Get#(dType)) readRespVec = newVector();
  Vector#(banks, Put#(Tuple2#(rAddr, dType))) writeReqVec = newVector();
  for (Integer b=0; b<valueOf(banks); b=b+1) begin
    readReqVec[b] = (interface Put;
                        method Action put(rAddr ra);
                          rams[b].portA.request.put(BRAMRequest{write: False, 
                                            responseOnWrite: False, 
                                            address:ra, 
                                            datain: ?} );
                        endmethod
                    endinterface);
    readRespVec[b] = (interface Get;
                        method ActionValue#(dType) get();
                          let v <- rams[b].portA.response.get();
                          return v;
                        endmethod
                      endinterface);
    writeReqVec[b] = (interface Put;
                        method Action put(Tuple2#(rAddr, dType) wreq);
                          rams[b].portB.request.put(BRAMRequest{write: True, 
                                            responseOnWrite: False, 
                                            address: tpl_1(wreq), 
                                            datain: tpl_2(wreq)} );
                        endmethod
                      endinterface);
  end

  interface readReq = readReqVec;
  interface readResp = readRespVec;
  interface writeReq = writeReqVec;
endmodule
