//
//  CDiskKit.c
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

#include "CDiskKit.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <IOKit/storage/ata/ATASMARTLib.h>

#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

_Static_assert(sizeof(NVMeSMARTData) == 512, "NVMe SMART log must be 512 bytes");
_Static_assert(sizeof(ATASMARTData) == 512, "ATA SMART data must be 512 bytes");
_Static_assert(sizeof(ATASMARTDataThresholds) == 512, "ATA SMART thresholds must be 512 bytes");

// MARK: - NVMe

int32_t DKNVMeReadHealth(uint32_t service,
                         uint8_t *smartLog512,
                         uint8_t *identify4096,
                         int32_t *identifyResult)
{
    if (identifyResult) *identifyResult = kIOReturnNotReady;
    if (!smartLog512) return kIOReturnBadArgument;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService((io_service_t)service,
                                                         kIONVMeSMARTUserClientTypeID,
                                                         kIOCFPlugInInterfaceID,
                                                         &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        return kr != KERN_SUCCESS ? kr : kIOReturnError;
    }

    IONVMeSMARTInterface **nvme = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
                                           CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
                                           (LPVOID *)&nvme);
    if (hr != S_OK || nvme == NULL) {
        IODestroyPlugInInterface(plugin);
        return kIOReturnUnsupported;
    }

    NVMeSMARTData smart;
    memset(&smart, 0, sizeof(smart));
    IOReturn result = (*nvme)->SMARTReadData(nvme, &smart);
    if (result == kIOReturnSuccess) {
        memcpy(smartLog512, &smart, sizeof(smart));
    }

    if (identify4096) {
        void *buffer = calloc(1, 4096);
        if (buffer) {
            IOReturn ir = (*nvme)->GetIdentifyData(nvme, buffer, 0);
            if (identifyResult) *identifyResult = ir;
            if (ir == kIOReturnSuccess) memcpy(identify4096, buffer, 4096);
            free(buffer);
        }
    }

    (*nvme)->Release(nvme);
    IODestroyPlugInInterface(plugin);
    return result;
}

// MARK: - ATA

static IOATASMARTInterface **DKCreateATAInterface(io_service_t service, IOCFPlugInInterface ***pluginOut)
{
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service,
                                                         kIOATASMARTUserClientTypeID,
                                                         kIOCFPlugInInterfaceID,
                                                         &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) return NULL;

    IOATASMARTInterface **ata = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
                                           CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID),
                                           (LPVOID *)&ata);
    if (hr != S_OK || ata == NULL) {
        IODestroyPlugInInterface(plugin);
        return NULL;
    }
    *pluginOut = plugin;
    return ata;
}

int32_t DKATAReadSMART(uint32_t service,
                       uint8_t *data512,
                       uint8_t *thresholds512,
                       uint8_t *identify512,
                       uint8_t *errorLog512,
                       uint8_t *selfTestLog512,
                       bool *thresholdExceeded,
                       uint32_t *availability)
{
    if (availability) *availability = 0;
    if (thresholdExceeded) *thresholdExceeded = false;

    IOCFPlugInInterface **plugin = NULL;
    IOATASMARTInterface **ata = DKCreateATAInterface((io_service_t)service, &plugin);
    if (ata == NULL) return kIOReturnUnsupported;

    uint32_t avail = 0;

    // Read-only: if S.M.A.R.T. is turned off on the drive the read fails, and it is left off. Turning it
    // on changes the drive's configuration, which is the user's decision, not the monitor's.
    ATASMARTData data;
    memset(&data, 0, sizeof(data));
    IOReturn result = (*ata)->SMARTReadData(ata, &data);
    if (result == kIOReturnSuccess && data512) {
        memcpy(data512, &data, sizeof(data));
        avail |= DKATAHasData;
    }

    if (thresholds512) {
        ATASMARTDataThresholds thresholds;
        memset(&thresholds, 0, sizeof(thresholds));
        if ((*ata)->SMARTReadDataThresholds(ata, &thresholds) == kIOReturnSuccess) {
            memcpy(thresholds512, &thresholds, sizeof(thresholds));
            avail |= DKATAHasThresholds;
        }
    }

    Boolean exceeded = false;
    if ((*ata)->SMARTReturnStatus(ata, &exceeded) == kIOReturnSuccess) {
        if (thresholdExceeded) *thresholdExceeded = exceeded ? true : false;
        avail |= DKATAHasStatus;
    }

    if (identify512) {
        UInt32 outSize = 0;
        if ((*ata)->GetATAIdentifyData(ata, identify512, 512, &outSize) == kIOReturnSuccess && outSize > 0) {
            avail |= DKATAHasIdentify;
        }
    }

    if (errorLog512) {
        // SMART summary error log (log address 01h)
        if ((*ata)->SMARTReadLogAtAddress(ata, 0x01, errorLog512, 512) == kIOReturnSuccess) {
            avail |= DKATAHasErrorLog;
        }
    }

    if (selfTestLog512) {
        // SMART self-test log (log address 06h)
        if ((*ata)->SMARTReadLogAtAddress(ata, 0x06, selfTestLog512, 512) == kIOReturnSuccess) {
            avail |= DKATAHasSelfTestLog;
        }
    }

    (*ata)->Release(ata);
    IODestroyPlugInInterface(plugin);

    if (availability) *availability = avail;
    return result;
}

int32_t DKATAStartSelfTest(uint32_t service, bool extended)
{
    IOCFPlugInInterface **plugin = NULL;
    IOATASMARTInterface **ata = DKCreateATAInterface((io_service_t)service, &plugin);
    if (ata == NULL) return kIOReturnUnsupported;
    IOReturn result = (*ata)->SMARTExecuteOffLineImmediate(ata, extended ? true : false);
    (*ata)->Release(ata);
    IODestroyPlugInInterface(plugin);
    return result;
}

// MARK: - authopen

int DKAuthOpenReadOnly(const char *devicePath)
{
    if (devicePath == NULL) return DKAuthOpenLaunchFailed;

    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return DKAuthOpenLaunchFailed;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, sockets[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, sockets[0]);

    // authopen -stdoutpipe -o <O_RDONLY> <path>
    char flags[16];
    snprintf(flags, sizeof(flags), "%d", 0 /* O_RDONLY */);
    char *const argv[] = {
        (char *)"/usr/libexec/authopen",
        (char *)"-stdoutpipe",
        (char *)"-o",
        flags,
        (char *)devicePath,
        NULL
    };

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(sockets[1]);

    if (spawnResult != 0) {
        close(sockets[0]);
        return DKAuthOpenLaunchFailed;
    }

    int fd = DKAuthOpenNoDescriptor;
    char byte = 0;
    struct iovec iov = { .iov_base = &byte, .iov_len = sizeof(byte) };
    union {
        struct cmsghdr header;
        char buffer[CMSG_SPACE(sizeof(int))];
    } control;
    memset(&control, 0, sizeof(control));

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.buffer;
    message.msg_controllen = sizeof(control.buffer);

    ssize_t received;
    do {
        received = recvmsg(sockets[0], &message, 0);
    } while (received < 0 && errno == EINTR);

    if (received > 0) {
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
        if (cmsg && cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS
            && cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
            memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
        }
    }
    close(sockets[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return fd;
}
