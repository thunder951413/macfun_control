#include "FanBarC.h"

mach_port_t fanbar_mach_task_self(void) {
  return mach_task_self();
}
