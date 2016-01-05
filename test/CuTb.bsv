import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import StmtFSM::*;

import Common::*;
import Cu::*;


typedef 4 CU_W;
typedef 8 CU_H;
typedef 1024 DEPTH;
Integer testNumOps = 16;

typedef enum {
  INIT,
  FILL_CACHE,
  RUN
} TestState deriving (Bits, Eq);

function dtype genDataA(dtype d, dtype w) 
  provisos ( Arith#(dtype) );
  return (d+w);
endfunction

function dtype genDataB(dtype d, dtype h) 
  provisos ( Arith#(dtype) );
  return 2*(d+h);
endfunction

function dtype goldResult(dtype w, dtype h)
  provisos ( Arith#(dtype) );
  dtype res = 0;
  for (Integer i=0; i<testNumOps; i=i+1) begin
    res = genDataA(fromInteger(i), w) * genDataB(fromInteger(i), h) + res;
  end
  return res;
endfunction


module mkCuTb();

  CU#(CU_W, CU_H, DEPTH, UInt#(32)) cu <- mkCU();
  Reg#(Bit#(32)) cyc <- mkReg(0);
  Reg#(Bit#(32)) dep <- mkReg(0);
  Reg#(TestState) st <- mkReg(INIT);

  rule incrementCyc;
    cyc <= cyc + 1;
  endrule

  //Fill A, B caches with some data
  //Issue read requests to cache and op to PE
  //Check MAC sum
  Stmt test = 
  seq
    for (dep <= 0; dep < fromInteger(valueOf(DEPTH)); dep <= dep+1) seq
      action 
        for (Integer w=0; w < valueOf(CU_W); w=w+1) begin
          UInt#(32) data = unpack(genDataA(dep, fromInteger(w)));
          cu.aCacheWrite[w].put( tuple2(truncate(dep), data) );
          $display("[%d] CuTb: aWrite (%x %x) = %x", cyc, dep, w, data);
        end

        for (Integer h=0; h < valueOf(CU_H); h=h+1) begin
          UInt#(32) data = unpack(genDataB(dep, fromInteger(h)));
          cu.bCacheWrite[h].put( tuple2(truncate(dep), data) );
          $display("[%d] CuTb: bWrite (%x %x) = %x", cyc, dep, h, data);
        end
        
      endaction 
    endseq

    $display("[%d] Begin MAC...", cyc);
  endseq; //Stmt test
    
  //mkAutoFSM(test);
  FSM testFSM <- mkFSM(test);

  rule fillCache if (st==INIT);
    testFSM.start;
    st <= FILL_CACHE;
  endrule

  rule endFilleCache if (st==FILL_CACHE && testFSM.done);
    st <= RUN;
  endrule

  //Issue MAC ops
  for (Integer h=0; h<valueOf(CU_H); h=h+1) begin
    Reg#(Bit#(32)) numMacs <- mkReg(0);
    rule issueOps if (st==RUN && numMacs <= fromInteger(testNumOps));
      OpCode op = (numMacs == fromInteger(testNumOps)) ? DONE : MAC;
      cu.peOp[h].put(op);
      numMacs <= numMacs + 1;
    endrule
  end

  //Issue cache read requests. 
  for (Integer w=0; w<valueOf(CU_W); w=w+1) begin
    Reg#(Bit#(32)) numMacs <- mkReg(0);
    rule issueARead if (st==RUN && numMacs < fromInteger(testNumOps));
      cu.aCacheReadReq[w].put( tuple2(fromInteger(w), truncate(numMacs)) );
      //cu.aCacheReadReq[w].put( tuple2(0, truncate(numMacs)) );
      numMacs <= numMacs + 1;
      $display("[%d] A[port=%x] read addr (%x %x)", cyc, w, w, numMacs);
    endrule
  end
  
  for (Integer h=0; h<valueOf(CU_H); h=h+1) begin
    Reg#(Bit#(32)) numMacs <- mkReg(0);
    rule issueBRead if (st==RUN && numMacs < fromInteger(testNumOps));
      cu.bCacheReadReq[h].put( truncate(numMacs) );
      numMacs <= numMacs + 1;
      $display("[%d] B[port=%x] read addr %x", cyc, h, numMacs);
    endrule
  end

  //Get results
  Vector#(CU_W, Reg#(Bool)) done <- replicateM(mkReg(False));
  for (Integer w=0; w<valueOf(CU_W); w=w+1) begin
    Reg#(Bit#(32)) hCnt <- mkReg(0);
    rule getCResult; 
      let v <- cu.cCacheRead[w].get();
      UInt#(32) goldV = unpack(goldResult(fromInteger(w), hCnt));
      hCnt <= hCnt + 1;
      $display("[%d] Out[port=%x] [%x] = %d; exp = %d", cyc, w, hCnt, v, goldV);
      if (goldV != v) begin
        $display("[%d] ***ERROR: incorrect output", cyc);
        //$finish;
      end
      done[w] <= (hCnt==fromInteger(valueOf(CU_H)-1));
    endrule
  end

  function dtype andVec(dtype a);
    return a;
  endfunction 

  rule endTest if (all(andVec, readVReg(done)));
    $display("Test complete");
    $finish;
  endrule


endmodule

