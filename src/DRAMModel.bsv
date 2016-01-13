import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;
import RegFile::*;

import Common::*;


//import "BDPI" function ActionValue#(Bit#(32)) simDramInit();
//import "BDPI" function Action simDramWrite(Bit#(32) bAddr, Bit#(32) rAddr, Bit#(32) cAddr, Bit#(64) mask, Bit#(512) data);
//import "BDPI" function ActionValue#(Bit#(512)) simDramRead(Bit#(32) bAddr, Bit#(32) rAddr, Bit#(32) cAddr);

typedef 14 LOG_DDR_ROWS;
typedef 7 LOG_DDR_COLS;
typedef 3 LOG_DDR_BANKS;

typedef TExp#(LOG_DDR_ROWS) DDR_ROWS; //16384
//Each chip has 128 cols of 64-bit wide, burst over 8 cycles with width 8-bit. 
// 8 chips per dimm concatenated to form a 64-bit interface
// 8 bursts of 64-bit --> 512-bit mem interface
// This is the number of 512-bit words per column
typedef TExp#(LOG_DDR_COLS) DDR_COLS;
typedef TExp#(LOG_DDR_BANKS) DDR_BANKS; 

typedef Bit#(LOG_DDR_ROWS) RAddr;
typedef Bit#(LOG_DDR_COLS) CAddr;
typedef Bit#(LOG_DDR_BANKS) BAddr;

typedef enum {
  RDY,
  WAIT
} CtrlState deriving (Bits, Eq);

typedef struct {
  Bool isOpen;
  RAddr openedRow;
} BankState deriving (Bits, Eq);
  

typedef struct {
  Bit#(64) rtag; //Read request tag
  RAddr rAddr; 
  CAddr cAddr; 
  BAddr bAddr; 
  Bit#(64) mask; 
  Bit#(512) data;
} DRAMReq deriving (Bits, Eq);


// Modelled after DDR3_User_V7 in XilinxVirtex7DDR3.bsv
interface DRAMUser;
   method    Bool              	     init_done;
   method    Action request(RAddr ra, CAddr ca, BAddr ba, Bit#(64) mask, Bit#(512) data);
   method    ActionValue#(Bit#(512)) read_data;
endinterface

//NOTE: Adding synth boundary will screw up the enqueuing into the bank FIFOs since
// the request method will block if ANY FIFO is full. This is for sim only, so we leave
// out the synth boundary. 
// Requests are not reordered

(* synthesize *)
module mkDRAMModel(DRAMUser);
  Integer t_NewRow = 5; //Roughly tCL+tRCD+tRP @ 100MHz
  Integer t_OpenedRow = 2; //Roughly tCL @ 100MHz

  Vector#(DDR_BANKS, RegFile#(Bit#(TAdd#(LOG_DDR_ROWS, LOG_DDR_COLS)), Bit#(512))) mem <- replicateM(mkRegFileFull());

  // This 64-bit counter is the READ request tag. 64-bit is overkill. We just
  // need it to be larger than the number of requests in flight. It's ok for it
  // to wrap around. Used for serializing READ requests only. 
  Reg#(Bit#(64)) rTagCnt <- mkReg(0); 
  Reg#(Bit#(64)) rspTagCnt <- mkReg(0); 
  // These queues need to be somewhat deep to avoid blocking other queues
  Vector#(DDR_BANKS, FIFO#(DRAMReq)) reqQs <- replicateM(mkFIFO());
  //FIFO#(DRAMReq) reqInQ <- mkFIFO();
  Vector#(DDR_BANKS, FIFOF#(Tuple2#(Bit#(64), Bit#(512)))) respQs <- replicateM(mkFIFOF());
  FIFO#(Bit#(512)) rDataQ <- mkFIFO();
  Reg#(Bit#(32)) cyc <- mkReg(0);
 
  rule incrementCyc;
    cyc <= cyc + 1;
  endrule

  /*
  for (Integer b=0; b<valueOf(DDR_BANKS); b=b+1) begin
    rule distrReq if (reqInQ.first.bAddr==fromInteger(b));
     let req = reqInQ.first;
     reqQs[b].enq(req);
     reqInQ.deq;
    endrule
  end
  */

  //Emulate latencies here. Track which row is open in each bank
  // Ensure the DRAM bandwidth is realistic depending on the Fmax of the design

  for (Integer b=0; b<valueOf(DDR_BANKS); b=b+1) begin
    Reg#(BankState) bankSt <- mkReg(BankState{isOpen: False, openedRow: ?});
    Reg#(CtrlState) ctrlSt <- mkReg(RDY);
    Reg#(Bit#(32)) delayCnt <- mkReg(0);
    let req = reqQs[b].first;
    rule handleReq if (ctrlSt==RDY);
      //TODO we need to subtract 2 cycle in order to get the correct delay
      // Compute the delay based on whether we need to open a new row
      delayCnt <= ( bankSt.isOpen && bankSt.openedRow==req.rAddr ) ? 
                          fromInteger(t_OpenedRow) : fromInteger(t_NewRow);
      ctrlSt <= WAIT;
    endrule

    rule waitReadWrite (ctrlSt==WAIT);
      if (delayCnt==0) begin
        //Read or write data
        if (req.mask==0) begin //read
          // v <- simDramRead(b, req.rAddr, req.cAddr);
          let v = mem[b].sub({req.rAddr, req.cAddr});
          respQs[b].enq(tuple2(req.rtag, v));
        end
        else begin //write, applying mask
          Bit#(512) expandedMask = 0;
          for (Integer i=0; i<64; i=i+1) begin
            expandedMask[(i*8+7):(i*8)] = (req.mask[i]==1) ? 8'hFF : 8'h00;
          end
          let v = mem[b].sub({req.rAddr, req.cAddr});
          let updateData = (v & ~expandedMask) | (req.data & expandedMask);
          mem[b].upd({req.rAddr, req.cAddr}, updateData);
          //simDramWrite(b, req.rAddr, req.cAddr, req.mask, req.data);
        end
        bankSt <= BankState{isOpen: True, openedRow: req.rAddr};
        reqQs[b].deq;
        ctrlSt <= RDY;
        //$display("[%d] Done request at bank=%x", cyc, b);
      end
      else begin
        delayCnt <= delayCnt - 1;
      end
    endrule

  end //for banks
  
/////////////////////////////////////////
// Choose one of the ways to do this
/////////////////////////////////////////
 /* 
  // BSC will determine these conflict and give a warning
  for (Integer b=0; b<valueOf(DDR_BANKS); b=b+1) begin
    rule orderReadResp if (tpl_1(respQs[b].first)==rspTagCnt);
      rDataQ.enq(tpl_2(respQs[b].first));
      rspTagCnt <= rspTagCnt + 1;
    endrule
  end
*/
  //This appears to work...
  // Basically use a function to generate mutually exclusive conditions for each rule
  // if (a), if (!a && b), if (!a && !b && c) ... 
  // The notEmpty check is essential, otherwise a rule fires only when all prior fifos are notEmpty. 
  function Bool genCondition(Integer i);
    if (i==0) return True;
    else begin
      return !(respQs[i-1].notEmpty && tpl_1(respQs[i-1].first)==rspTagCnt) && genCondition(i-1);
      //return !(tpl_1(respQs[i-1].first)==rspTagCnt) && genCondition(i-1);
    end
  endfunction
  for (Integer b=0; b<valueOf(DDR_BANKS); b=b+1) begin
    rule orderReadResp if (genCondition(b) && respQs[b].notEmpty && tpl_1(respQs[b].first)==rspTagCnt);
    //rule orderReadResp if (genCondition(b) && tpl_1(respQs[b].first)==rspTagCnt);
      rDataQ.enq(tpl_2(respQs[b].first));
      rspTagCnt <= rspTagCnt + 1;
      respQs[b].deq;
    endrule
  end

  /*
  //I think we need to use recursion here. FIXME: this function is wrong
  function Bool order(Integer i); 
    if (i==0) begin
      return (respQs[i].notEmpty && tpl_1(respQs[i].first)==rspTagCnt);
    end
    else begin
      return (respQs[i].notEmpty && tpl_1(respQs[i].first)==rspTagCnt && !order(i-1));
    end
  endfunction

  for (Integer b=0; b<valueOf(DDR_BANKS); b=b+1) begin
    rule orderReadResp if (order(b));
      rDataQ.enq(tpl_2(respQs[b].first));
      rspTagCnt <= rspTagCnt + 1;
    endrule
  end
  */
      
      
/*
  //TODO: check the schedule of this rule
  rule orderReadResp;
    if (tpl_1(respQs[0].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[0].first));
      rspTagCnt <= rspTagCnt + 1;
    end
    else if (tpl_1(respQs[1].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[1].first));
      rspTagCnt <= rspTagCnt + 1;
    end
    else if (tpl_1(respQs[2].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[2].first));
      rspTagCnt <= rspTagCnt + 1;
    end
    else if (tpl_1(respQs[3].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[3].first));
      rspTagCnt <= rspTagCnt + 1;
    end
    else if (tpl_1(respQs[4].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[4].first));
      rspTagCnt <= rspTagCnt + 1;
    end
    else if (tpl_1(respQs[5].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[5].first));
      rspTagCnt <= rspTagCnt + 1;
    end
    else if (tpl_1(respQs[6].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[6].first));
      rspTagCnt <= rspTagCnt + 1;
    end
    else if (tpl_1(respQs[7].first)==rspTagCnt) begin
      rDataQ.enq(tpl_2(respQs[7].first));
      rspTagCnt <= rspTagCnt + 1;
    end
  endrule
*/


   method Bool init_done; 
     return True;
   endmethod

   method Action request(RAddr ra, CAddr ca, BAddr ba, Bit#(64) mask, Bit#(512) data);
     $display("[%d] DRAM Request [%x %x %x] m=%x", cyc, ra, ca, ba, mask);
     if (mask==0) begin 
       rTagCnt <= rTagCnt + 1;
     end
     DRAMReq req = DRAMReq{ rtag: rTagCnt, rAddr: ra, cAddr: ca, bAddr: ba, mask: mask, data: data };
     //reqInQ.enq(req);
     reqQs[ba].enq(req);
   endmethod
     
   method ActionValue#(Bit#(512)) read_data;
     $display("[%d] DRAM Read %x", cyc, rDataQ.first);
     rDataQ.deq;
     return rDataQ.first;
   endmethod


endmodule

