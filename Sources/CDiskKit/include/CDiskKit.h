//
//  CDiskKit.h
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

#ifndef CDISKKIT_H
#define CDISKKIT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the 512-byte NVMe "SMART / Health Information" log page (Log ID 02h)
/// through Apple's NVMeSMARTLib plug-in, and optionally the 4096-byte
/// Identify Controller data structure.
///
/// @param service        io_service_t that carries the "NVMe SMART Capable" property.
/// @param smartLog512    Output buffer of at least 512 bytes.
/// @param identify4096   Optional output buffer of at least 4096 bytes (may be NULL).
/// @param identifyResult Optional IOReturn of the identify command.
/// @return IOReturn of the SMART read (0 on success).
int32_t DKNVMeReadHealth(uint32_t service,
                         uint8_t *smartLog512,
                         uint8_t *identify4096,
                         int32_t *identifyResult);

/// Bit flags describing which ATA SMART structures were read successfully.
enum {
    DKATAHasData        = 1 << 0,
    DKATAHasThresholds  = 1 << 1,
    DKATAHasIdentify    = 1 << 2,
    DKATAHasStatus      = 1 << 3,
    DKATAHasErrorLog    = 1 << 4,
    DKATAHasSelfTestLog = 1 << 5,
};

/// Reads ATA SMART data through Apple's ATASMARTLib plug-in (internal SATA/AHCI
/// drives, or USB drives when a SAT SMART driver publishes the interface).
///
/// All buffers must be at least 512 bytes. `availability` receives DKATAHas* flags.
/// @return IOReturn of the SMART READ DATA command (0 on success).
int32_t DKATAReadSMART(uint32_t service,
                       uint8_t *data512,
                       uint8_t *thresholds512,
                       uint8_t *identify512,
                       uint8_t *errorLog512,
                       uint8_t *selfTestLog512,
                       bool *thresholdExceeded,
                       uint32_t *availability);

/// Starts an ATA SMART self-test (short or extended) in off-line mode.
int32_t DKATAStartSelfTest(uint32_t service, bool extended);

/// Opens a raw device read-only via /usr/libexec/authopen, which asks the user
/// for administrator authorization and passes back a file descriptor.
/// The calling process never runs as root.
/// @return An open file descriptor, or -1 if authorization failed / was cancelled.
int DKAuthOpenReadOnly(const char *devicePath);

#ifdef __cplusplus
}
#endif

#endif /* CDISKKIT_H */
