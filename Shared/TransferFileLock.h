#ifndef IMORA_TRANSFER_FILE_LOCK_H
#define IMORA_TRANSFER_FILE_LOCK_H
int imora_transfer_lock(int descriptor, int nonblocking);
int imora_transfer_unlock(int descriptor);
#endif
