import FIFO::*;

typedef enum {
  MAC, 
  DONE

} OpCode deriving (Bits, Eq, FShow);
