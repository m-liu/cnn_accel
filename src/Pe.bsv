import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAM::*;
import Connectable::*;
import GetPut::*;

import Common::*;

//=======================================================================
// 2D array of processing elements
//=======================================================================
interface PEArr#(numeric type w, numeric type h, type dType);
  interface Vector#(w, Put#(dType)) vA;
  interface Vector#(h, Put#(dType)) vB;
  interface Vector#(w, Get#(dType)) vRes;
  interface Vector#(h, Put#(OpCode)) vOp; //For now each row has the same op. TODO
endinterface


// Make a row of PEs that perform multiply-accumulate
// For now, they operate in sync.
module mkPEArray(PEArr#(w, h, dType))
  provisos( Bits#(dType, a__),
            Arith#(dType) );

  Vector#(h, Vector#(w, PE#(dType))) peArr <- replicateM(replicateM(mkPE()));

  //Make internal connections
  for (Integer hi = 0; hi < valueOf(h)-1; hi=hi+1) begin
    for (Integer wi = 0; wi < valueOf(w); wi=wi+1) begin
      // Connect forwarded path for input A down a column
      mkConnection(peArr[hi][wi].outA, peArr[hi+1][wi].inA);
      // Connect path for results "up" a column
      mkConnection(peArr[hi][wi].inRes, peArr[hi+1][wi].outRes);
    end

  end

  //throw out the last row of forwarded A inputs
  //TODO: more efficient way would be to get rid of these FIFOs in the last PE
  for (Integer wi = 0; wi < valueOf(w); wi=wi+1) begin
    rule drainOutA; 
      let trash <- peArr[valueOf(h)-1][wi].outA.get();
    endrule
  end


  Vector#(h, Put#(OpCode)) opVec = newVector();
  Vector#(h, Put#(dType)) bVec = newVector();
  for (Integer hi = 0; hi < valueOf(h); hi=hi+1) begin
    opVec[hi] = (interface Put;
                  method Action put(OpCode p);
                    for (Integer wi = 0; wi < valueOf(w); wi=wi+1) begin
                      peArr[hi][wi].op.put(p);
                    end
                  endmethod
                endinterface);
    bVec[hi] = (interface Put;
                  method Action put(dType d);
                    for (Integer wi = 0; wi < valueOf(w); wi=wi+1) begin
                      peArr[hi][wi].inB.put(d);
                    end
                  endmethod
                endinterface);
   end

  Vector#(w, Put#(dType)) aVec = newVector();
  Vector#(w, Get#(dType)) resVec = newVector();
  for (Integer wi=0; wi<valueOf(w); wi=wi+1) begin
    aVec[wi] = (interface Put;
                  method Action put(dType d);
                    peArr[0][wi].inA.put(d);
                  endmethod
                endinterface);
    resVec[wi] = (interface Get;
                    method ActionValue#(dType) get();
                      let r <- peArr[0][wi].outRes.get();
                      return r;
                    endmethod
                  endinterface);
  end
    
  interface Vector vA = aVec; //head(peArr).inA;
  interface Vector vB = bVec; 
  interface Vector vRes = resVec; //head(peArr).outRes;
  interface Vector vOp = opVec;


endmodule

//=======================================================================
// Single Processing Element
//=======================================================================

interface PE#(type dType);
  interface Put#(dType) inA;
  interface Put#(dType) inB;
  interface Get#(dType) outA; //forwarded A
  interface Put#(dType) inRes; //forwarded result
  interface Get#(dType) outRes; //result out from top
  interface Put#(OpCode) op; 
endinterface


module mkPE(PE#(dType))
  provisos( Bits#(dType, a__),
            Arith#(dType) );

  //TODO: make these 1 element?
  //TODO: so many FIFOs here... Optimization: create the FIFOs outside this module and pass in as parameter. 
  //TODO: optimization: fuse opQ with inQ as a single Q
  FIFO#(dType) inAQ <- mkFIFO();
  FIFO#(dType) inBQ <- mkFIFO();
  FIFO#(dType) outAQ <- mkFIFO();
  FIFO#(dType) outResQ <- mkFIFO();
  FIFOF#(dType) inResQ <- mkFIFOF(); //TODO: we can try to remove this..
  FIFO#(OpCode) opQ <- mkFIFO();

  Reg#(dType) acc <- mkReg(0);

  let currOp = opQ.first;

  rule compute if (currOp==MAC);
    opQ.deq;
    let a = inAQ.first;
    //TODO: multi-cycle this
    acc <= acc + (a * inBQ.first);
    outAQ.enq(a);
    inAQ.deq;
    inBQ.deq;
  endrule

  rule outputResult if (currOp==DONE && !inResQ.notEmpty);
    opQ.deq;
    acc <= 0;
    outResQ.enq(acc);
  endrule

  // Forwarding of results from PEs below take priority over result from
  // current PE
  rule forwardResult;
    outResQ.enq(inResQ.first);
    inResQ.deq();
  endrule

  interface Put inA = toPut(inAQ);
  interface Put inB = toPut(inBQ);
  interface Get outA = toGet(outAQ);
  interface Put inRes = toPut(inResQ); 
  interface Get outRes = toGet(outResQ);
  interface Put op = toPut(opQ);

endmodule





  
  //This is too complicated. Abandon this code...
  /*
  function Vector#(n, Get#(dType)) getPEOutA ( Vector#(n, PE#(dType)) peVec );
    Vector#(n, Get#(dType)) retIfc = newVector();
    for (Integer i=0; i<valueOf(n); i=i+1) begin
      retIfc[i] = peVec[i].outA;
    end
    return retIfc;
  endfunction
  function Vector#(n, Put#(dType)) getPEInA ( Vector#(n, PE#(dType)) peVec );
    Vector#(n, Put#(dType)) retIfc = newVector();
    for (Integer i=0; i<valueOf(n); i=i+1) begin
      retIfc[i] = peVec[i].inA;
    end
    return retIfc;
  endfunction

  zipWithM(mkConnection, map(getPEOutA, peArr), map(getPEInA, peArr)); 
  */

//function that takes in a vector of put interfaces and a vector of values 
//function replicateOp(PE#(OpCode) ifc, OpCode v);
//  ifc.op.put(v);
//endfunction 

// Vector of Put PE interfaces 
// Vector of replicated single values
// return a single PEArr.vOp Put interface

//To be called by fold --> nested f(f(f()))
/*
function Put#(OpCode) replicateOp(PE#(OpCode) ifc);
  return ( interface Put;
            method Action put(OpCode p);

              ifc.op.put(p);
            endmethod
           endinterface);
endfunction
*/


