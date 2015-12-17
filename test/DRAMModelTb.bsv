import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import RegFile::*;
import StmtFSM::*;

import Common::*;

import DRAMModel::*;

// Yeah..this data generation can be done better. 
function Bit#(512) genData(RAddr ra, CAddr ca, BAddr ba);
  Bit#(16) xa = zeroExtend(ba)^zeroExtend(ra);
  Bit#(16) xa2 = zeroExtend(ra)^zeroExtend(ca);
  Bit#(16) xa3 = zeroExtend(ba)^zeroExtend(ca);
  Bit#(32) tmp = zeroExtend({ba, ra, ca});
  Bit#(32) tmp2 = zeroExtend({ca, ra, ba});
  Bit#(32) tmp3 = zeroExtend({ca<<3, ra<<2, ba<<1});
  Bit#(64) tmp4 = zeroExtend({xa, xa2, xa3});
  return zeroExtend({xa, tmp4, tmp3, tmp2, tmp});
endfunction 

function Tuple3#(RAddr, CAddr, BAddr) genAddrFromCnt(Bit#(32) cnt);
  RAddr r = truncate(cnt>>(valueOf(LOG_DDR_BANKS)+valueOf(LOG_DDR_COLS))); 
  CAddr c = truncate(cnt>>valueOf(LOG_DDR_BANKS));
  BAddr b = truncate(cnt);
  return tuple3(r, c, b);
endfunction


function Action checkData(Bit#(32) cyc, RAddr ra, CAddr ca, BAddr ba, Bit#(64) mask, Bit#(512) testData);
  return action
    $display("[%d] Check req [%x %x %x]", cyc, ra, ca, ba);
    let expected = genData(ra, ca, ba);
    if (mask!=0 && mask !=-1) begin
      $display("***[%d] WARNING: checkData currently incompatible with masks", cyc);
    end
    if (testData!=expected) begin
      $display("***[%d] ERROR: mismatch detected, expected %x, got %x", cyc, expected, testData); 
      $finish;
    end
  endaction;
endfunction


module mkTopTb();
  DRAMUser dram <- mkDRAMModel();
  Reg#(Bit#(32)) cyc <- mkReg(0);
  Reg#(Bit#(32)) reqAddr <- mkReg(0);
  Reg#(Bit#(32)) respAddr <- mkReg(0);

  rule incrementCyc;
    cyc <= cyc + 1;
  endrule
  
  Stmt test = 
  seq
    //Single basic read/write
    $display("[%d] Starting basic test", cyc);
    dram.request(4, 23, 2, -1, genData(4, 23, 2));
    dram.request(4, 23, 2, 0, ?);
    action 
      let d <- dram.read_data;
      checkData(cyc,4,23,2,-1,d);
    endaction 
    
    //Masked write
    dram.request(4, 24, 2, 64'h3, genData(4,24,2));
    dram.request(4, 24, 2, 64'h0, ?);
    action 
      let d <- dram.read_data;
      // Last 2 bytes are valid (with mask=3)
      if ( (genData(4,24,2) & 512'hFFFF) != (d & 512'hFFFF) ) begin
        $display("***[%d] ERROR: mismatch detected on masked writes");
        $finish;
      end
    endaction 

    //Multiple read/write
    $display("[%d] Starting seq write test", cyc);
    //Must use while loops (instead of for loops) to fire every cycle
    while (reqAddr< fromInteger(valueOf(DDR_BANKS)*valueOf(DDR_COLS)*64)) seq
      action 
        match{.r, .c, .b} = genAddrFromCnt(reqAddr);
        dram.request(r, c, b, -1, genData(r,c,b));
        reqAddr <= reqAddr + 1;
      endaction
    endseq
    $display("[%d] End write test", cyc);
    reqAddr <= 0;

    $display("[%d] Starting seq read test", cyc);
    par 
      while (reqAddr<1024) seq
        action 
          match{.r, .c, .b} = genAddrFromCnt(reqAddr);
          dram.request(r, c, b, 0, ?);
          reqAddr <= reqAddr + 1;
        endaction
      endseq

      while (respAddr<1024) seq
        action
          match{.r, .c, .b} = genAddrFromCnt(respAddr);
          let d <- dram.read_data();
          checkData(cyc, r, c, b, -1, d);
          respAddr <= respAddr + 1;
        endaction
      endseq
    endpar
    reqAddr <= 0;
    respAddr <= 0;
    $display("[%d] End read test", cyc);

    //Different banks only; diff rows only; diff cols only
    //Diff rows on one bank, diff cols on another bank. Is everything still in order?
    //Check timing
    $display("[%d] Starting row read test", cyc);
    par 
      while (reqAddr<64) seq
        action 
          RAddr r = truncate(reqAddr);
          dram.request(r, 0, 0, 0, ?);
          reqAddr <= reqAddr + 1;
        endaction
      endseq

      while (respAddr<64) seq
        action
          let d <- dram.read_data();
          RAddr r = truncate(respAddr);
          checkData(cyc, r, 0, 0, -1, d);
          respAddr <= respAddr + 1;
        endaction
      endseq
    endpar
    reqAddr <= 0;
    respAddr <= 0;

    $display("[%d] Starting col read test", cyc);
    par 
      while (reqAddr<64) seq
        action 
          CAddr c = truncate(reqAddr);
          dram.request(0, c, 0, 0, ?);
          reqAddr <= reqAddr + 1;
        endaction
      endseq

      while (respAddr<64) seq
        action
          let d <- dram.read_data();
          CAddr c = truncate(respAddr);
          checkData(cyc, 0, c, 0, -1, d);
          respAddr <= respAddr + 1;
        endaction
      endseq
    endpar
    reqAddr <= 0;
    respAddr <= 0;

    $display("[%d] Starting row/col read test", cyc);
    par 
      //Read column of bank #0 and row of bank #1
      while (reqAddr<64) seq
        action 
          CAddr c = truncate(reqAddr);
          dram.request(0, c, 0, 0, ?);
        endaction
        action 
          RAddr r = truncate(reqAddr);
          dram.request(r, 0, 1, 0, ?);
          reqAddr <= reqAddr + 1;
        endaction
      endseq

      while (respAddr<64) seq
        action
          let d <- dram.read_data();
          CAddr c = truncate(respAddr);
          checkData(cyc, 0, c, 0, -1, d);
        endaction
        action
          let d <- dram.read_data();
          RAddr r = truncate(respAddr);
          checkData(cyc, r, 0, 1, -1, d);
          respAddr <= respAddr + 1;
        endaction
      endseq
    endpar
    reqAddr <= 0;
    respAddr <= 0;

    $display("[%d] All tests passed!", cyc);

  endseq; //Stmt test
  
  mkAutoFSM(test);

endmodule

