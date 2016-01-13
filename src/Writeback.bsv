import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;
import DRAMModel::*;

typedef struct {
  RAddr ra;
  CAddr ca;
  BAddr ba;
} DRAMAddr deriving (Bits, Eq);

typedef struct {
  DRAMAddr dramAddr; 
  Bit#(TLog#(w)) cacheBa;
} WBReq#(numeric type w) deriving (Bits, Eq);

interface WriteBack#(numeric type w, numeric type dep, type dType);
  interface Vector#(dep, Vector#(w, Put#(dType))) cCacheRead;
  interface Put#(WBReq#(w)) wbReq;
endinterface

function dType getFirst(FIFO#(dType) q);
  return q.first;
endfunction

//Note: do not add synth boundary here
module mkWriteBack#(DRAMUser dram)( WriteBack#(w, dep, dType) )
  provisos (  Bits#(dType, a__),
              Mul#(dep, a__, 512) );

  //TODO: eliminate
  Vector#(w, Vector#(dep, FIFO#(dType))) cQ <- replicateM(replicateM(mkFIFO()));
  Vector#(w, FIFO#(DRAMAddr)) outAddrQ <- replicateM(mkFIFO());

  Vector#(w, Bit#(512)) wbLine = newVector();
  for (Integer wi=0; wi<valueOf(w); wi=wi+1) begin
    wbLine[wi] = pack( map(getFirst, cQ[wi]) ); 
  end

  //FIXME: these rules conflict on write to dram
  for (Integer wi=0; wi<valueOf(w); wi=wi+1) begin
    rule writeDram;
      let dAddr = outAddrQ[wi].first;
      dram.request( dAddr.ra, dAddr.ca, dAddr.ba, -1, wbLine[wi] );
      outAddrQ[wi].deq;
      for (Integer di=0; di<valueOf(dep); di=di+1) begin
        cQ[wi][di].deq;
      end
    endrule
  end

  
  Vector#(dep, Vector#(w, Put#(dType))) cVec = newVector();
  for (Integer di=0; di<valueOf(dep); di=di+1) begin
    for (Integer wi=0; wi<valueOf(w); wi=wi+1) begin
      cVec[di][wi] = toPut(cQ[wi][di]); //Note index swap
    end
  end
    
  interface cCacheRead = cVec; 
  interface Put wbReq;
    method Action put(WBReq#(w) req);
      outAddrQ[req.cacheBa].enq(req.dramAddr);
    endmethod
  endinterface 

endmodule


module mkTop();
  DRAMUser dram <- mkDRAMModel();
  WriteBack#(ARR_W, ARR_D, DTYPE) wb <- mkWriteBack(dram);
endmodule


