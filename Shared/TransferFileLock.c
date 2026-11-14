#include "TransferFileLock.h"
#include <sys/file.h>

int imora_transfer_lock(int descriptor, int nonblocking) {
    return flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0));
}
int imora_transfer_unlock(int descriptor) {
    return flock(descriptor, LOCK_UN);
}
