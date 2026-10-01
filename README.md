# OrientMark result transfer v0

[English](README.md) | [Русский](README.ru.md)

Repository: [orient-mark/result-transfer](https://github.com/orient-mark/result-transfer).
Development branch: `dev`. License: [MIT](LICENSE).

Shared pure Dart package for the OrientMark `sportsman` and `event-organizer`
applications. It defines the participant result format, splits it into packets,
and reassembles the received packets with integrity checks. QR rendering,
animation, camera access, and file storage are implemented by the applications.

## Installation

Add the Git dependency to your application's `pubspec.yaml`:

```yaml
dependencies:
  result_transfer:
    git:
      url: https://github.com/orient-mark/result-transfer.git
      ref: dev
```

Then fetch dependencies:

```bash
flutter pub get
```

Import the package:

```dart
import 'package:result_transfer/result_transfer.dart';
```

The package is downloaded from GitHub; a local checkout beside the applications
is not required. The resolved commit is recorded in `pubspec.lock`. After changes
are published to `dev`, update the dependency in each application:

```bash
flutter pub upgrade result_transfer
```

Requires Dart SDK `^3.13.0`. The package is distributed through Git and is not
published to pub.dev.

## Transfer

This is a sequential animated QR protocol, **not BC-UR/fountain coding**.
Frames repeat in a loop; a missed frame can be collected on the next cycle.
No network or acknowledgement channel is used. Only the organizer can confirm
successful receipt. The sender continues displaying frames until the user leaves.

## Result file

The result is transmitted as UTF-8 JSON:

```json
{
  "format": "orientmark-result",
  "version": 0,
  "name": "Alex",
  "surname": "Smith",
  "number_chip": 42,
  "start": null,
  "finish": "2026-10-01T09:30:00.000Z",
  "count_cp": 2,
  "marks": [
    { "code": "31", "time": "2026-10-01T09:10:00.000Z" },
    { "code": "32", "time": "2026-10-01T09:20:00.000Z" }
  ]
}
```

| Field | Description |
| --- | --- |
| `format` | Document format identifier: `"orientmark-result"` for an OrientMark result. |
| `version` | Document format version, currently `0` until release. |
| `name` | Participant's given name. |
| `surname` | Participant's surname. |
| `number_chip` | Participant's chip number, an integer. |
| `start` | Start mark time, or `null` if no start was recorded. Example when present: `"2026-10-01T09:00:00.000Z"`. |
| `finish` | Required finish mark time. Must not be `null`. |
| `count_cp` | Number of checkpoint marks. Must equal the length of `marks`; `0` when there are no marks. |
| `marks` | Array of marks in recorded order; `[]` when there are no marks. |
| `marks[].code` | Checkpoint code, a string. |
| `marks[].time` | Absolute checkpoint mark time. |

All timestamps use ISO-8601 UTC; the `Z` suffix denotes UTC. Order and repeated
visits are preserved. No course validation is performed. Zero marks and an
absent start are valid. ResultDocument is an immutable snapshot, not a reference
to the mutable split stored by the athlete app.

## QR frame

Each QR frame carries one packet as JSON. The example below contains the result
from the previous section, serialized without whitespace into a single packet:

```json
{
  "qr": "orientmark",
  "v": 0,
  "id": "9981a7beb9622bc86110afb33735b6e0a9a199d1fd823c1212c0c240c63a982e",
  "index": 0,
  "total": 1,
  "bytes": 259,
  "hash": "9981a7beb9622bc86110afb33735b6e0a9a199d1fd823c1212c0c240c63a982e",
  "data": "eyJmb3JtYXQiOiJvcmllbnRtYXJrLXJlc3VsdCIsInZlcnNpb24iOjAsIm5hbWUiOiJBbGV4Iiwic3VybmFtZSI6IlNtaXRoIiwibnVtYmVyX2NoaXAiOjQyLCJzdGFydCI6bnVsbCwiZmluaXNoIjoiMjAyNi0xMC0wMVQwOTozMDowMC4wMDBaIiwiY291bnRfY3AiOjIsIm1hcmtzIjpbeyJjb2RlIjoiMzEiLCJ0aW1lIjoiMjAyNi0xMC0wMVQwOToxMDowMC4wMDBaIn0seyJjb2RlIjoiMzIiLCJ0aW1lIjoiMjAyNi0xMC0wMVQwOToyMDowMC4wMDBaIn1dfQ=="
}
```

| Field | Description |
| --- | --- |
| `qr` | Protocol identifier: `"orientmark"`. |
| `v` | Packet protocol version, currently `0`. Separate from the result document's `version` field. |
| `id` | Transfer identifier: SHA-256 of the entire UTF-8 result file. Shared by all packets of the transfer. |
| `index` | Packet index, starting at `0`. |
| `total` | Total number of packets required to assemble the result. |
| `bytes` | Size of the entire result file in bytes before base64 encoding. |
| `hash` | SHA-256 of this packet's bytes before base64 encoding. |
| `data` | Packet bytes encoded as a base64 string. |

In this example, `total` is `1` and `bytes` is `259`. The `id` and `hash`
values match because the only packet contains the entire file.

The file is split by bytes, then each packet is base64-encoded. UTF-8 is decoded
only after assembly: a packet boundary may split a multibyte character, such as
a Cyrillic letter.

Packet size is 360 bytes except the last. Limits: 1024 packets, 368640 bytes per
file, and 1024 characters per QR frame string. The assembler checks packet
metadata and hash before retaining data, then verifies the whole-file hash and
document structure before returning the result. Hashes detect corruption but do
not authenticate the sender.

Packets can arrive in any order; duplicates are ignored. Packets with a different
transfer identifier are ignored until assembly is reset. An incomplete transfer
does not produce a result. Failure to validate the assembled file resets assembly,
allowing the result to be scanned again.

**Future protocol versions will not support this format.** The sender and
receiver must use compatible protocol versions.

## Physical device testing

Verify the complete transfer on two physical devices:

1. Start transmitting a result from a sending application, such as an athlete application.
2. Start receiving QR packets in a receiving application on the second device.
3. Keep the QR within the camera's view until the complete result is received.
4. Compare the received participant details, timestamps, and marks with the original result.

Check a finish without checkpoint marks, a long split, interrupted and resumed
transmission, missed frames, repeated packets, another participant after resetting
reception, and camera permission denial. Assess reading speed at different frame
rates and under different lighting conditions.

Physical transfer speed and reliability have not yet been verified on devices.
