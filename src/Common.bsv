import FIFO::*;

typedef enum {
  MAC, 
  DONE

} OpCode deriving (Bits, Eq, FShow);

typedef 4 ARR_W;
typedef 16 ARR_H;
typedef 16 ARR_D;
typedef 1024 CACHE_DEP;

typedef UInt#(32) DTYPE;

