import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import Arbiter::*;

import Common::*;


// N bank BRAM cache, with N read ports that can read any bank (mux/noc in front)
// and N write ports that can only access bank[N] 

// bAddr: bank address; rAddr: row address within a bank
interface BankedCache#(numeric type banks, numeric type depth, type bAddr, type rAddr, type dType);
  interface Vector#(banks, Put#(Tuple2#(bAddr, rAddr))) readReq;
  interface Vector#(banks, Get#(dType)) readResp;
  interface Vector#(banks, Put#(Tuple2#(rAddr, dType))) writeReq;
endinterface

(*synthesize*)
module mkBankedBRAMCacheSynth(BankedCache#(ARR_W, CACHE_DEP, Bit#(TLog#(ARR_W)), Bit#(TLog#(CACHE_DEP)), DTYPE));
  BankedCache#(ARR_W, CACHE_DEP, Bit#(TLog#(ARR_W)), Bit#(TLog#(CACHE_DEP)), DTYPE) bc <- mkBankedBRAMCache();
  return bc;
endmodule



//TODO: optimization: if we assume PE rows operate in sync, we can use one
// wide interface instead of a vector of interfaces
//TODO: Currently assumes response always drains and fixed latency BRAM. 
// Otherwise we may have out-of-orderness, which may need tags/completion bufs. 

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

  Vector#(banks, FIFOF#(Tuple2#(bAddr, rAddr))) reqBufs <- replicateM(mkFIFOF());
  Vector#(banks, FIFOF#(dType)) respBufs <- replicateM(mkFIFOF());
  //TODO: FIFO depth corresponds to configured BRAM latency. 
  // We can get rid of this if we use BRAMCore directly
  // Tracks the source port of the request
  Vector#(banks, FIFO#(bAddr)) reqSrcQ <- replicateM(mkSizedFIFO(4)); 

  function aType getFirst(FIFOF#(aType) q);
    return q.first;
  endfunction

  // Vector of ba and ra from reqBufs.first 
  Vector#(banks, bAddr) baVec = map(tpl_1, map(getFirst, reqBufs));
  Vector#(banks, rAddr) raVec = map(tpl_2, map(getFirst, reqBufs));
  Vector#(banks, Arbiter_IFC#(banks)) readReqArbs <- replicateM(mkArbiter(False)); 
  for (Integer bo=0; bo<valueOf(banks); bo=bo+1) begin
    for (Integer bi=0; bi<valueOf(banks); bi=bi+1) begin
      rule readReqArbitrate if (reqBufs[bi].notEmpty && baVec[bi]==fromInteger(bo));
        readReqArbs[bo].clients[bi].request();
      endrule

      let gid = readReqArbs[bo].grant_id;
      rule readCacheBank if (gid==fromInteger(bi) && reqBufs[bi].notEmpty && baVec[bi]==fromInteger(bo));
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
  Vector#(banks, Arbiter_IFC#(banks)) readRespArbs <- replicateM(mkArbiter(False)); 
  for (Integer bi=0; bi<valueOf(banks); bi=bi+1) begin
    for (Integer bo=0; bo<valueOf(banks); bo=bo+1) begin
      rule readRespArbitrate if (reqSrcQ[bo].first == fromInteger(bi));
        readRespArbs[bi].clients[bo].request();
      endrule

      let gid = readRespArbs[bi].grant_id;
      rule getCacheBankResponse if (gid==fromInteger(bo) && reqSrcQ[bo].first == fromInteger(bi));
        let d <- rams[bo].portA.response.get();
        reqSrcQ[bo].deq;
        respBufs[bi].enq(d);
      endrule
    end
  end


  for (Integer bo=0; bo<valueOf(banks); bo=bo+1) begin
    rule warnFull if (!respBufs[bo].notFull);
      $display("**ERROR: cache response buffer is full");
      $finish;
    endrule
  end
  
  Vector#(banks, Put#(Tuple2#(rAddr, dType))) wReqVec = newVector();
  for (Integer b=0; b<valueOf(banks); b=b+1) begin
    wReqVec[b] = (interface Put;
                    method Action put(Tuple2#(rAddr, dType) wreq);
                      rams[b].portB.request.put(BRAMRequest{ write: True,
                                                      responseOnWrite: False,
                                                      address: tpl_1(wreq),
                                                      datain: tpl_2(wreq) });
                    endmethod
                  endinterface);
  end

  interface readReq = map(toPut, reqBufs);
  interface readResp = map(toGet, respBufs);
  interface writeReq = wReqVec;

endmodule



//================================
// Instantiate for testing
//================================
module mkTop();
  Vector#(ARR_D, BankedCache#(ARR_W, CACHE_DEP, Bit#(TLog#(ARR_W)), Bit#(TLog#(CACHE_DEP)), DTYPE)) aCache <- replicateM(mkBankedBRAMCacheSynth());
endmodule


//================================
// Old code kept for reference
//================================

// (1) Simple fixed priority conflicting rules. Compiler will give warning. 

  // Use a fixed priority arbiter for now. Lower ports have priority. 
  // This is default behavior (with compiler warnings)
  // TODO: do we need a rotating priority arb?
  /*
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
  */


  /*
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
  */
 

// (2) Fixed priority. Non-conflicting rules. Resolved by function. 

  /*
  function Bool genFixedArb(Integer i, Integer j);
    if (i==0) return True;
    else begin
      return !(reqBufs[i-1].notEmpty && baVec[i-1]==fromInteger(j)) 
                && genFixedArb(i-1, j);
    end
  endfunction

  for (Integer bo=0; bo<valueOf(banks); bo=bo+1) begin
    for (Integer bi=0; bi<valueOf(banks); bi=bi+1) begin
      rule readCacheBank if (genFixedArb(bi, bo) && reqBufs[bi].notEmpty && baVec[bi]==fromInteger(bo));
        rams[bo].portA.request.put(BRAMRequest{write: False, 
                                responseOnWrite: False, 
                                address:raVec[bi], 
                                datain: ?} );
        reqSrcQ[bo].enq(fromInteger(bi));
        reqBufs[bi].deq;
      endrule
    end
  end
  */




