import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;


// N bank BRAM cache, with B read ports that can read all B banks (mux in front)
// and B write ports that can only access its own bank

// bAddr: bank address; rAddr: row address within a bank
//interface CReadReq#(type bAddr, type rAddr);
//  method Action req(bAddr ba, rAddr ra);
//endinterface

interface BankedCache#(numeric type banks, numeric type depth, type bAddr, type rAddr, type dType);
  interface Vector#(banks, Put#(Tuple2#(bAddr, rAddr))) readReq;
  interface Vector#(banks, Get#(dType)) readResp;
endinterface

//TODO: optimization: if we assume PE rows operate in sync, we can use one
// wide interface instead of a vector of interfaces
//TODO: how to deal with bank conflicts? Perhaps use a bramcore and a layer of arbitratioN

module mkBankedBRAMCache(BankedCache#(banks, depth, bAddr, rAddr, dType))
 provisos (Bits#(dType, a_),
            PrimIndex#(bAddr, a__),
            //Check that bAddr and rAddr types match the depth/bank number
            Bits#(bAddr, bsz),
            Bits#(rAddr, rsz),
            Log#(banks, bsz),
            Log#(depth, rsz));

  BRAM_Configure cfg = defaultValue;
  cfg.memorySize = valueOf(depth);
  Vector#(banks, BRAM2Port#(rAddr, dType)) rams <- replicateM(mkBRAM2Server(cfg));

  Vector#(banks, FIFO#(Tuple2#(bAddr, rAddr))) reqBufs <- replicateM(mkFIFO());
  Vector#(banks, FIFOF#(dType)) respBufs <- replicateM(mkFIFOF());
  //TODO: FIFO depth corresponds to configured BRAM latency. 
  // We can get rid of this if we use BRAMCore directly
  // Tracks the source port of the request
  Vector#(banks, FIFO#(bAddr)) reqSrcQ <- replicateM(mkSizedFIFO(4)); 

  function aType getFirst(FIFO#(aType) q);
    return q.first;
  endfunction
  // Vector of ba and ra from reqBufs.first 
  Vector#(banks, bAddr) baVec = map(tpl_1, map(getFirst, reqBufs));
  Vector#(banks, rAddr) raVec = map(tpl_2, map(getFirst, reqBufs));
  
  // Use a fixed priority arbiter for now. Lower ports have priority. 
  // This is default behavior (with compiler warnings)
  // TODO: do we need a rotating priority arb?
  for (Integer bo=0; bo<valueOf(banks); bo=bo+1) begin
    for (Integer bi=0; bi<valueOf(banks); bi=bi+1) begin
      rule readCacheBank if (baVec[bi]==fromInteger(bo));
        rams[bo].portA.request.put(BRAMRequest{write: False, 
                                responseOnWrite: False, 
                                address:raVec[bi], 
                                datain: ?} );
        reqSrcQ[bo].enq(fromInteger(bi));
        reqBufs[bi].deq;
      endrule
    end
  end


  // Get response data from BRAM. Use reqSrcQ to determine where to send the result
  // Note: responses will not be out of order if the outputQ always drains. 
  for (Integer bi=0; bi<valueOf(banks); bi=bi+1) begin
    for (Integer bo=0; bo<valueOf(banks); bo=bo+1) begin
      // Technically there can never be a case where two reqSrcQs have the same destination
      // since we assume the respBufs always drain. This is an optimziation for later. TODO
      rule getCacheBankResponse if (reqSrcQ[bo].first == fromInteger(bi));
        let d <- rams[bo].portA.response.get();
        reqSrcQ[bo].deq;
        respBufs[bi].enq(d);
      endrule
    end
  end

  for (Integer bo=0; bo<valueOf(banks); bo=bo+1) begin
    rule warnFull if (!respBufs[bo].notFull);
      $display("**ERROR: cache response buffer is full");
    endrule
  end
  
  interface readReq = map(toPut, reqBufs);
  interface readResp = map(toGet, respBufs);

endmodule


module mkTop();
  BankedCache#(4, 16, Bit#(2), Bit#(4), UInt#(32)) bc <- mkBankedBRAMCache();
/*

  Reg#(Bit#(2)) ba <- mkReg(0);
  rule test;
    bc.readReq[0].put(tuple2(ba,3));
  endrule
*/
endmodule


