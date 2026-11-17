//
//  shell_request_bytes.cpp
//
//  Prints the exact requests the driver sends for one command of the Drobo's firmware shell
//  (system operation 0x0A) and compares them with the layout in protocol notes 11.22. The
//  requests come from the same functions the driver calls (DroboProtocol.h), so this fails
//  if the driver's bytes drift from the notes. Nothing is sent anywhere.
//
//    xcrun clang++ -std=gnu++17 -Wall -Werror -o /tmp/shell_request_bytes tests/shell_request_bytes.cpp
//    /tmp/shell_request_bytes ["command text"]
//

#include <cstdio>
#include <cstring>

#include "../DroboDriver/DroboProtocol.h"

static void
Print(const char * label, const uint8_t * bytes, size_t count)
{
    printf("%-22s", label);
    for (size_t i = 0; i < count; i++) {
        printf(" %02X", bytes[i]);
    }
    printf("\n");
}

static bool
Same(const char * label, const uint8_t * built, const uint8_t * documented, size_t count)
{
    if (memcmp(built, documented, count) == 0) {
        return true;
    }
    printf("MISMATCH in %s\n", label);
    Print("  built", built, count);
    Print("  protocol notes", documented, count);
    return false;
}

int
main(int argc, char ** argv)
{
    const char *  text     = argc > 1 ? argv[1] : "state error verbose";
    const uint8_t sequence = 0x2A;
    const size_t  length   = strlen(text);
    if (length == 0 || length > 255) {
        fprintf(stderr, "the command text must be 1 to 255 bytes\n");
        return 2;
    }

    uint8_t command[16];
    uint8_t firstRead[16];
    uint8_t laterRead[16];
    DroboShellCommandCDB(command, sequence, (uint16_t) length);
    DroboShellReadCDB(firstRead, sequence, true);
    DroboShellReadCDB(laterRead, sequence, false);

    // Protocol notes 11.22, written out by hand (not through the functions above):
    //   EA 10 00 0A <seq> 00 20 <len16 BE> 00   + ASCII command text, data-out
    //   EA 10 80 0A <seq> 00 20 08 00 00        first read, 0x800 bytes data-in
    //   EA 10 80 0A <seq> 00 00 08 00 00        every later read
    // The CDB field of a passthrough request is 16 bytes; the last six stay zero.
    const uint8_t documentedCommand[16]   = { 0xEA, 0x10, 0x00, 0x0A, sequence, 0x00, 0x20,
                                              (uint8_t) (length >> 8), (uint8_t) length, 0x00 };
    const uint8_t documentedFirstRead[16] = { 0xEA, 0x10, 0x80, 0x0A, sequence, 0x00, 0x20, 0x08, 0x00, 0x00 };
    const uint8_t documentedLaterRead[16] = { 0xEA, 0x10, 0x80, 0x0A, sequence, 0x00, 0x00, 0x08, 0x00, 0x00 };

    printf("command text: \"%s\" (%zu bytes, no terminating zero, no newline), sequence %02X\n\n",
           text, length, sequence);
    Print("1. text, data-out", command, 10);
    Print("   payload", (const uint8_t *) text, length);
    Print("2. first read, data-in", firstRead, 10);
    Print("3. later reads", laterRead, 10);
    printf("\npassthrough flags: text 0x%08X, reads 0x%08X (both with the direct-buffer bit)\n",
           kDroboPassthroughDataOut | kDroboPassthroughDirectBuffer,
           kDroboPassthroughDataInOrNone | kDroboPassthroughDirectBuffer);

    bool ok = true;
    ok = Same("the command text request", command, documentedCommand, sizeof(command)) && ok;
    ok = Same("the first read", firstRead, documentedFirstRead, sizeof(firstRead)) && ok;
    ok = Same("a later read", laterRead, documentedLaterRead, sizeof(laterRead)) && ok;
    printf("\n%s\n", ok ? "All three requests match protocol notes 11.22."
                        : "The driver's requests do NOT match protocol notes 11.22.");
    return ok ? 0 : 1;
}
