import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import StmtFSM::*;

import Common::*;
import CacheBanked::*;

typedef 4 BANKS;
typedef 1024 DEPTH;
typedef Bit#(TLog#(BANKS)) BankAddr;
typedef Bit#(TLog#(DEPTH)) DepAddr;

typedef enum {
  CLEAR,
  WRITE,
  NC_READ,
  C_READ,
  DONE
} TestState deriving (Bits, Eq);


function UInt#(32) genData(BankAddr ba, DepAddr da);
  return unpack(zeroExtend({ba, da}));
endfunction

function Tuple2#(BankAddr, DepAddr) genAddrFromCnt(Bit#(32) cnt, Integer p, TestState st);
    BankAddr ba = 0;
    DepAddr da = 0;
    if (st==NC_READ) begin
      //Generate non-conflicting bank addresses. Each port should rotate access
      // to different banks on each cycle. This wraps around. 
      ba = truncate(cnt + fromInteger(valueOf(BANKS) - p - 1));
      da = truncate( cnt>> valueOf(TLog#(BANKS)) );
    end
    else begin
      // Generate conflicting accesses on first two banks
      ba = (cnt[1:0]==3) ? 0 : 1;
      da = truncate( cnt>> valueOf(TLog#(BANKS)) );
    end
    return tuple2(ba, da);
endfunction


module mkCacheBankedTb();
  BankedCache#(BANKS, DEPTH, BankAddr, DepAddr, UInt#(32)) cache <- mkBankedBRAMCache();
  Reg#(Bit#(32)) cyc <- mkReg(0);
  Reg#(TestState) testSt <- mkReg(CLEAR);
  Reg#(TestState) nextTestSt <- mkReg(WRITE);

  //Request/response counters
  Reg#(Bit#(32)) wrCnt <- mkReg(0);
  Vector#(BANKS, Reg#(Bool)) doneRead <- replicateM(mkReg(False));
  Vector#(BANKS, Reg#(Bit#(32))) respAddr <- replicateM(mkReg(0));
  Vector#(BANKS, Reg#(Bit#(32))) reqAddr <- replicateM(mkReg(0));


  rule incrementCyc;
    cyc <= cyc + 1;
  endrule

  rule clear if (testSt==CLEAR);
    writeVReg(doneRead, replicate(False));
    writeVReg(respAddr, replicate(0));
    writeVReg(reqAddr, replicate(0));
    testSt <= nextTestSt;
  endrule

  // Write to cache via all ports in parallel
  rule writeCache if (testSt==WRITE);
    for (Integer p=0; p<valueOf(BANKS); p=p+1) begin
      DepAddr da = truncate(wrCnt);
      let data = genData(fromInteger(p),da);
      $display("[%d] Writing cache [%x %x]: %x", cyc, p, da, data);
      cache.writeReq[p].put(tuple2(da, data));
    end
    wrCnt <= wrCnt + 1;
    testSt <= (wrCnt < fromInteger(valueOf(DEPTH))) ? testSt : NC_READ;
  endrule
  
  //issue requests to ALL request ports
  for (Integer p=0; p<valueOf(BANKS); p=p+1) begin

    Integer num_reqs = 64;

    rule readReq if ( (testSt==NC_READ || testSt==C_READ) && reqAddr[p] < fromInteger(num_reqs));
      let addr = genAddrFromCnt(reqAddr[p], p, testSt);
      $display("[%d] read req [%x %x] at port [%x]", cyc, tpl_1(addr), tpl_2(addr), p);
      cache.readReq[p].put(addr);
      reqAddr[p] <= reqAddr[p]+1;
    endrule

    rule readData if ( (testSt==NC_READ || testSt==C_READ) && !doneRead[p]);
      let addr = genAddrFromCnt(respAddr[p], p, testSt);
      let d <- cache.readResp[p].get();
      match{.ba, .da} = addr;
      let expd = genData(ba, da);
      $display("[%d] addr [%x %x] read: %x at port [%x]", cyc, ba, da, d, p);
      if (d != expd) begin
        $display("***ERROR: mismatch on read: d=%x, want=%x", d, expd);
      end
      Bool isDone = (respAddr[p] >= fromInteger(num_reqs-1));
      doneRead[p] <= isDone; //Stop after 64 
      respAddr[p] <= respAddr[p]+1;
    endrule
      
  end

  function Bool andVec(Bool a);
    return a;
  endfunction 

  rule ncReadDone if (testSt==NC_READ && all(andVec, readVReg(doneRead)));
    $display("[%d] non-conflict read DONE!", cyc);
    testSt <= CLEAR;
    nextTestSt <= C_READ;
  endrule

  rule cReadDone if (testSt==C_READ && all(andVec, readVReg(doneRead)));
    $display("[%d] conflict read DONE!", cyc);
    testSt <= CLEAR;
    nextTestSt <= DONE;
  endrule

  rule done if (testSt==DONE);
    $display("All pass");
    $finish;
  endrule
endmodule

