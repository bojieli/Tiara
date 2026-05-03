// Tiara on-the-wire packet format.
//
// Custom Ethertype 0x88B5 (IEEE Std 802 local experimental).  Frames
// are minimal — a fixed-size invocation request and a fixed-size
// response — so the in-NIC parser is a simple compare on a few byte
// positions rather than a general header walker.
//
// Byte order on the wire is big-endian for the Ethernet header
// (per IEEE 802.3) and little-endian for the Tiara payload (matches
// the host's natural integer byte order, so userspace doesn't have to
// byte-swap when packing/unpacking).
//
// AXIS framing on Corundum's AU50 25g platform: 512-bit (64-byte) data
// width, byte 0 lives in tdata[7:0], byte i in tdata[8*i+7 : 8*i].
//
// Invocation packet (96 bytes, spans 2 AXIS beats):
//   bytes  0.. 5 : dst MAC
//   bytes  6..11 : src MAC
//   bytes 12..13 : ethertype = 0x88B5 (big-endian: byte 12 = 0x88)
//   bytes 14..17 : magic     = 0x010071A5 (little-endian: byte 14 = 0xA5,
//                              byte 15 = 0x71, bytes 16/17 = 0x01/0x00)
//                              -- read as `magic_word == 32'h0100_71A5`
//   bytes 18..19 : op_kind   = 1  (invoke)   /  2  (response)
//   bytes 20..23 : operator_id
//   bytes 24..27 : task_id
//   bytes 28..31 : flags
//   bytes 32..95 : args[0..7] (8 x 64 bit, little-endian)
//
// Response packet (64 bytes, fits in one AXIS beat):
//   bytes  0.. 5 : dst MAC (was the invoker's src)
//   bytes  6..11 : src MAC (NIC's MAC)
//   bytes 12..13 : 0x88B5
//   bytes 14..17 : magic
//   bytes 18..19 : op_kind = 2
//   bytes 20..23 : operator_id (echoed)
//   bytes 24..27 : task_id    (echoed)
//   bytes 28..29 : status: bit0=done, bit1=err
//   bytes 30..31 : reserved
//   bytes 32..63 : result[0..3] (4 x 64 bit, little-endian)

`ifndef TIARA_PACKET_SVH
`define TIARA_PACKET_SVH

`define TIARA_ETHERTYPE      16'h88B5
`define TIARA_MAGIC          32'h0100_71A5
`define TIARA_KIND_INVOKE    16'h0001
`define TIARA_KIND_RESPONSE  16'h0002

// Byte-order helpers — pull byte i from a little-endian-packed word.
`define TIARA_BYTE(word, i) (word[8*(i)+7 -: 8])

`endif
