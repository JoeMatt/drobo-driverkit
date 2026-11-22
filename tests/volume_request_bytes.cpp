//
//  volume_request_bytes.cpp
//
//  Prints the exact requests the driver sends to create or delete a volume and to reset the
//  Drobo, and compares them with the layouts in protocol notes 11.26. The requests come from
//  the same functions the driver calls (DroboProtocol.h), so this fails if the driver's bytes
//  drift from the notes. It also decodes a volume list (management page 0x07) the way the
//  driver does before it lets a delete through. Nothing is sent anywhere.
//
//    xcrun clang++ -std=gnu++17 -Wall -Werror -o /tmp/volume_request_bytes tests/volume_request_bytes.cpp
//    /tmp/volume_request_bytes
//

#include <cstdio>
#include <cstring>

#include "../DroboDriver/DroboProtocol.h"

static int failures = 0;

static void
Check(const char * label, const uint8_t * built, const uint8_t * documented, size_t count)
{
    printf("%-26s", label);
    for (size_t i = 0; i < count; i++) {
        printf(" %02X", built[i]);
    }
    const bool same = memcmp(built, documented, count) == 0;
    printf("  %s\n", same ? "ok" : "DIFFERS FROM THE NOTES");
    if (!same) {
        failures++;
    }
}

static void
Expect(const char * label, bool condition)
{
    printf("%-26s %s\n", label, condition ? "ok" : "FAILED");
    if (!condition) {
        failures++;
    }
}

int
main()
{
    uint8_t cdb[16];

    // Reset: EA 10 00 02 <sequence> 00 21 00 01 00, one zero byte out.
    DroboSystemOperationCDB(cdb, kDroboOperationResetPack, 0x07, 1, false);
    const uint8_t reset[10] = { 0xEA, 0x10, 0x00, 0x02, 0x07, 0x00, 0x21, 0x00, 0x01, 0x00 };
    Check("reset CDB", cdb, reset, 10);

    // Next unique volume ID: EA 10 80 20 00 00 21 00 02 00, two bytes in.
    DroboSystemOperationCDB(cdb, kDroboOperationNextVolumeID, 0, (uint16_t) kDroboNextVolumeIDLength, true);
    const uint8_t nextID[10] = { 0xEA, 0x10, 0x80, 0x20, 0x00, 0x00, 0x21, 0x00, 0x02, 0x00 };
    Check("next volume ID CDB", cdb, nextID, 10);

    // Create: EA 10 00 12 00 00 21 00 0C 00, twelve bytes out.
    DroboSystemOperationCDB(cdb, kDroboOperationCreateVolume, 0, (uint16_t) kDroboCreateVolumeLength, false);
    const uint8_t create[10] = { 0xEA, 0x10, 0x00, 0x12, 0x00, 0x00, 0x21, 0x00, 0x0C, 0x00 };
    Check("create CDB", cdb, create, 10);

    // 16 TiB with unique ID 0x0105: size u64 big-endian, flags 0, 0, ID big-endian.
    uint8_t payload[12];
    DroboCreateVolumePayload(payload, 16ull << 40, 0x0105);
    const uint8_t createData[12] = { 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x05 };
    Check("create data", payload, createData, 12);

    // Delete: EA 10 00 13 00 00 21 00 04 00, four bytes out: ID big-endian, unit, 0.
    DroboSystemOperationCDB(cdb, kDroboOperationDeleteVolume, 0, (uint16_t) kDroboDeleteVolumeLength, false);
    const uint8_t remove[10] = { 0xEA, 0x10, 0x00, 0x13, 0x00, 0x00, 0x21, 0x00, 0x04, 0x00 };
    Check("delete CDB", cdb, remove, 10);
    uint8_t removeData[4];
    DroboDeleteVolumePayload(removeData, 0x0105, 3);
    const uint8_t removeDocumented[4] = { 0x01, 0x05, 0x03, 0x00 };
    Check("delete data", removeData, removeDocumented, 4);

    // A volume list as the 8D sends it (header byte 1 reads 04): unit 0, 16 TiB, ID 1; unit 3,
    // 2 TiB, ID 0x0105; an unused unit, which has ID 0 and still gets a record; and a unit
    // whose volume was deleted, which keeps its ID and has size 0.
    const uint8_t page[5 + 4 * 19] = {
        0x7A, 0x04, 0x00, 0x4D, 0x03,
        0x00, 0x11, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x08, 0x00, 0x01, 0x01, 0x06, 0x00,
        0x00, 0x11, 0x03, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x02, 0x08, 0x01, 0x05, 0x01, 0x06, 0x00,
        0x00, 0x11, 0x04, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x01, 0x06, 0x00,
        0x00, 0x11, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x01, 0x04, 0x01, 0x06, 0x00,
    };
    DroboVolumeRecord record;
    Expect("volume list: records", DroboVolumePageCount(page, sizeof(page)) == 4);
    Expect("volume list: deleted unit", DroboVolumePageRecord(page, sizeof(page), 3, &record) &&
           !DroboVolumeRecordInUse(&record) && record.unit == 5 && record.uniqueID == 0x0104);
    Expect("volume list: unused unit", DroboVolumePageRecord(page, sizeof(page), 2, &record) &&
           !DroboVolumeRecordInUse(&record) && record.unit == 4);
    Expect("volume list: first", DroboVolumePageRecord(page, sizeof(page), 0, &record) && record.unit == 0 &&
           record.sizeBytes == (16ull << 40) && record.uniqueID == 1 && record.nextID == 0x0106);
    Expect("volume list: second", DroboVolumePageRecord(page, sizeof(page), 1, &record) && record.unit == 3 &&
           record.sizeBytes == (2ull << 40) && record.uniqueID == 0x0105 && record.partitionCount == 2);
    Expect("volume list: in use", DroboVolumeRecordInUse(&record));
    Expect("volume list: past the end", !DroboVolumePageRecord(page, sizeof(page), 4, &record));
    // A page cut short holds only the records that are whole.
    Expect("volume list: truncated", DroboVolumePageCount(page, 5 + 19 + 4) == 1);
    Expect("volume list: empty", DroboVolumePageCount(page, 5) == 0);
    Expect("volume list: not a page", DroboVolumePageCount(removeData, sizeof(removeData)) == 0);

    return failures == 0 ? 0 : 1;
}
