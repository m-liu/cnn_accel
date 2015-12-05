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
endinterface


module mkVectorBRAMCache(VectorCache#(banks, depth, rAddr, dType))
  provisos (Bit#(dType, a_),
            Bit#(rAddr, rsz),
            Log#(depth, rsz));

  BRAM_Configure cfg = defaultValue;
  cfg.memorySize = valueOf(depth);
  Vector#(banks, BRAM2Port#(rAddr, dType)) rams <- replicateM(mkBRAM2Server(cfg));


  Vector#(banks, Put#(rAddr)) readReqVec = newVector();
  Vector#(banks, Get#(dType)) readRespVec = newVector();
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
  end

  interface readReq = readReqVec;
  interface readResp = readRespVec;
endmodule
