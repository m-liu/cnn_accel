import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import StmtFSM::*;

import Common::*;
import CacheFetcher::*;
import Writeback::*;
import DRAMModel::*;
import CuArray::*;

typedef enum {
  INIT,
  FILL_CACHE,
  COMPUTE,
  CHECK
} TestState deriving (Bits, Eq);

typedef 256 NUM_WEIGHTS;
typedef 512 NUM_INPUTS;
typedef 32 TEST_NUM_OPS; //Be careful not to overflow



//This is a very basic testbench
module mkCuArrayTb();
  Integer testNumOps = valueOf(TEST_NUM_OPS);
  
  DRAMUser dramIn <- mkDRAMModel();
  DRAMUser dramOut <- mkDRAMModel();
  CUArray#(ARR_W, ARR_H, ARR_D, CACHE_DEP, DTYPE) cuArr <- mkCuArray(dramIn, dramOut);
  Reg#(TestState) st <- mkReg(INIT);

  Reg#(Bit#(32)) cyc <- mkReg(0);
  rule incrementCyc;
    cyc <= cyc + 1;
  endrule

  Reg#(Bit#(32)) dAddr <- mkReg(0); //dram addr
  Reg#(Bit#(32)) wtAddr <- mkReg(0); //weight addr/count
  Reg#(Bit#(32)) inAddr <- mkReg(0); //input addr/count
  Reg#(Bit#(32)) waitReg <- mkReg(0); 

  //Function to write some initial data to DRAM
  function Action writeDRAMData(Bit#(32) addr);
    return (
    action
      Vector#(16, Bit#(32)) dataV = newVector();
      for (Integer i=0; i<16; i=i+1) begin
        dataV[i] = (addr*16) + fromInteger(i);
      end
      DRAMAddr da = unpack(truncate(addr));
      dramIn.request(da.ra, da.ca, da.ba, -1, pack(dataV));
    endaction );
  endfunction


  Stmt fillCache = 
  seq
    //Populate DRAM
    for (dAddr <= 0; dAddr < fromInteger(valueOf(NUM_WEIGHTS) + valueOf(NUM_INPUTS)); dAddr<=dAddr+1) seq
      writeDRAMData(dAddr);
    endseq

    //cache some weights
    wtAddr <= 0;
    while (wtAddr < fromInteger(valueOf(NUM_WEIGHTS))) seq
      action
        DRAMAddr da = unpack(truncate(wtAddr));
        Bit#(TLog#(ARR_H)) cba = truncate(wtAddr); //fill cache banks in sequence
        Bit#(TLog#(CACHE_DEP)) cda = truncate(wtAddr >> valueOf(TLog#(ARR_H))); 
        CacheFetchReq#(ARR_W, ARR_H, CACHE_DEP) cfreq = CacheFetchReq{dramAddr: da, 
                                                                      cacheSel: 1, 
                                                                      cacheBa: cba,
                                                                      cacheDa: cda};
        cuArr.cacheReq.put(cfreq);
        wtAddr <= wtAddr + 1;
      endaction
    endseq

    //cache some inputs. We assume inputs are stored consecutively after weights in DRAM addr space
    inAddr <= 0;
    while (inAddr < fromInteger(valueOf(NUM_INPUTS))) seq
      action
        DRAMAddr da = unpack(truncate(inAddr + fromInteger(valueOf(NUM_WEIGHTS))));
        Bit#(TLog#(ARR_W)) cba = truncate(inAddr); //fill cache banks in sequence
        Bit#(TLog#(CACHE_DEP)) cda = truncate(inAddr >> valueOf(TLog#(ARR_W))); 
        CacheFetchReq#(ARR_W, ARR_H, CACHE_DEP) cfreq = CacheFetchReq{dramAddr: da, 
                                                                      cacheSel: 0, 
                                                                      cacheBa: cba,
                                                                      cacheDa: cda};
        cuArr.cacheReq.put(cfreq);
        inAddr <= inAddr + 1;
      endaction
    endseq

    //Wait for cache to finish filling. TODO: this should be a response on write, but for now just wait
    for (waitReg <= 100; waitReg > 0; waitReg <= waitReg-1) seq
      action
        noAction;
      endaction 
    endseq
  endseq; //Stmt fillCache

  FSM fillCacheFSM <- mkFSM(fillCache);

  rule startFillCache if (st==INIT);
    fillCacheFSM.start;
    st <= FILL_CACHE;
  endrule

  rule endFilleCache if (st==FILL_CACHE && fillCacheFSM.done);
    st <= COMPUTE;
  endrule

  //Send ops, cache reqs and wb reqs
  //If we issue all requests in parallel using one rule, we have to be careful that
  // none of the request queues are blocked. Otherwise, we would be idle waiting. 
  // In this case, depth PEs all operate synchronously in parallel. Thus we issue
  // requests in parallel in depth dimension. 
  for (Integer hi=0; hi < valueOf(ARR_H); hi=hi+1) begin
    Reg#(Bit#(32)) numMacs <- mkReg(0);
    rule issueOpsInDep if (st==COMPUTE && numMacs <= fromInteger(testNumOps));
      OpCode op = (numMacs == fromInteger(testNumOps)) ? DONE : MAC;
      for (Integer di=0; di < valueOf(ARR_D); di=di+1) begin
        cuArr.peOp[di][hi].put(op);
        $display("[%d] cuArr[%d][%d] op MAC", cyc, di, hi);
      end
      numMacs <= numMacs + 1;
    endrule
  end

  //aCacheRead
  for (Integer wi=0; wi < valueOf(ARR_W); wi=wi+1) begin
    Reg#(Bit#(32)) numMacs <- mkReg(0);
    rule issueOpsInDep if (st==COMPUTE && numMacs <= fromInteger(testNumOps));
      for (Integer di=0; di < valueOf(ARR_D); di=di+1) begin
        cuArr.aCacheReadReq[di][wi].put( tuple2(fromInteger(wi), truncate(numMacs)) );
        $display("[%d] A[%d][port=%x] read addr (%x %x)", cyc, di, wi, wi, numMacs);
      end
      numMacs <= numMacs + 1;
    endrule
  end

  //bCacheRead
  for (Integer h=0; h<valueOf(ARR_H); h=h+1) begin
    Reg#(Bit#(32)) numMacs <- mkReg(0);
    rule issueBRead if (st==COMPUTE && numMacs < fromInteger(testNumOps));
      for (Integer di=0; di < valueOf(ARR_D); di=di+1) begin
        cuArr.bCacheReadReq[di][h].put( truncate(numMacs) );
        $display("[%d] B[%d][port=%x] read addr %x", cyc, di, h, numMacs);
      end
      numMacs <= numMacs + 1;
    endrule
  end

  //wbReq
  // h * w  results to write back. Write in sequence, across w then h
  Reg#(Bit#(32)) outAddr <- mkReg(0);
  Bit#(32) numWb = fromInteger(valueOf(TMul#(ARR_W, ARR_H)));
  rule issueWb if ( st==COMPUTE && outAddr < numWb );
    DRAMAddr da = unpack(truncate(outAddr));
    Bit#(TLog#(ARR_W)) cba = truncate(outAddr);
    WBReq#(ARR_W) wbr = WBReq{ dramAddr: da, cacheBa: cba };
    cuArr.wbReq.put(wbr);
    outAddr <= outAddr + 1;
    $display("[%d] wbReq [%d] dramAddr=%x, cba=%x", cyc, outAddr, da, cba);
    if (outAddr == numWb-1) begin
      st <= CHECK;
    end
  endrule
  




  //for a PE at position (w, h, d), result is
  // sum(i=0..127) of (64i+16h+d) * [4096 + (64i+16w+d)]
  // for the given set of constants
  function Vector#(ARR_D, UInt#(32)) genGoldDramData(DRAMAddr da);
    //Find PE position this DRAMAddr corresponds to
    Bit#(32) daPacked = zeroExtend(pack(da));
    Bit#(TLog#(ARR_W)) w = truncate(daPacked);
    Bit#(TLog#(ARR_H)) h = truncate(daPacked>>valueOf(TLog#(ARR_W)));
    Vector#(ARR_D, UInt#(32)) goldLine = replicate(0);

    Bool pass = True;
    for (Integer d=0; d<valueOf(ARR_D); d=d+1) begin
      UInt#(32) goldRes = 0;
      for (Integer i=0; i<valueOf(TEST_NUM_OPS); i=i+1) begin
        UInt#(32) iInt = fromInteger(i);
        UInt#(32) dInt = fromInteger(d);
        UInt#(32) wInt = unpack(zeroExtend(w));
        UInt#(32) hInt = unpack(zeroExtend(h));
        goldRes = goldRes + ( (64*iInt+16*hInt+dInt) * ( 4096 + (64*iInt+16*wInt+dInt) ) );
      end
      goldLine[d] = goldRes;
    end
    return goldLine;
  endfunction


  //check the results
  Stmt checkRes = 
  seq
    //Wait for all computations to finish. TODO: we need a response signal here
    for (waitReg <= 10000; waitReg > 0; waitReg <= waitReg-1) seq
      noAction;
    endseq

    for (dAddr <= 0; dAddr < numWb; dAddr<=dAddr+1) seq
      action
        DRAMAddr da = unpack(truncate(dAddr));
        dramOut.request(da.ra, da.ca, da.ba, 0, ?);
      endaction
      action 
        let rd <- dramOut.read_data;
        DRAMAddr da = unpack(truncate(dAddr));
        let goldLine = genGoldDramData(da);
        Bit#(512) goldLineBits = pack(goldLine);
        $display("Word by word comparisons:");
        Vector#(ARR_D, UInt#(32)) rdWord = unpack(rd);
        for (Integer di=0; di<valueOf(ARR_D); di=di+1) begin
          $display("[%d] exp=%d got=%d", di, goldLine[di], rdWord[di]);
        end
        if (goldLineBits != rd) begin
          $display("***ERROR: result mismatch, expected=%x, got=%x", goldLineBits, rd);
          $finish;
        end
        else begin
          $display("[%d] Line check passed!", cyc);
        end
      endaction 
    endseq
    $finish;
  endseq; //Stmt checkRes

  FSM checkResFSM <- mkFSM(checkRes);
  rule checkResults if (st==CHECK);
    checkResFSM.start;
  endrule

endmodule
