import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:intl/intl.dart';

import 'widgets.dart';

final snackBarKeyA = GlobalKey<ScaffoldMessengerState>();
final snackBarKeyB = GlobalKey<ScaffoldMessengerState>();
final snackBarKeyC = GlobalKey<ScaffoldMessengerState>();

String prettyException(String prefix, dynamic e) {
  if (e is FlutterBluePlusException) {
    return "$prefix ${e.errorString}";
  } else if (e is PlatformException) {
    return "$prefix ${e.message}";
  }
  return prefix + e.toString();
}

class UuidConsts {
  static final OTA_SERVICE = Guid("1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0");
  static final OTA_CONTROL = Guid("f7bf3564-fb6d-4e53-88a4-5e37e0326063");
  static final OTA_DATA = Guid("984227f3-34fc-4045-a5d0-2c581f81a153");
  static final TIME = Guid("b8470d55-e009-41ff-a648-817e4488ba57");
  static final BLINKY_SERVICE = Guid("de8a5aac-a99b-c315-0c80-60d4cbb51224");
}

enum States { idle, reconnecting, uploading, finalised }

class ViewActivity extends StatefulWidget {
  const ViewActivity({Key? key, required this.device}) : super(key: key);

  final BluetoothDevice device;

  @override
  State<StatefulWidget> createState() => _ViewActivityState();
}

class _ViewActivityState extends State<ViewActivity> {
  Uint8List data = Uint8List(0);
  var mtu = 255;
  var state = States.idle;
  var mtuDivisible = 0;
  var pack = 0;
  var otatime = 0;
  double pgss = 0;
  double bitrate = 0;
  BluetoothConnectionState connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> list = [];
  BluetoothCharacteristic? time;
  DateTime? current_time;

  List<int> _getRandomBytes() {
    final math = Random();
    return [math.nextInt(255), math.nextInt(255), math.nextInt(255), math.nextInt(255)];
  }

  @override
  void initState() {
    super.initState();

    widget.device.servicesStream.listen((event) {
      setState(() {
        list = event;
        time = event
            .firstWhere((element) => element.serviceUuid == UuidConsts.BLINKY_SERVICE)
            .characteristics
            .firstWhere((element) => element.characteristicUuid == UuidConsts.TIME);
      });

      if (time != null) {
        time!.onValueReceived.listen((event) {
          setState(() {
            current_time = getDateFromBytes(event);
          });
        });
      }
      var ctrlChar = event
          .firstWhere((element) => element.serviceUuid == UuidConsts.OTA_SERVICE)
          .characteristics
          .firstWhere((element) => element.characteristicUuid == UuidConsts.OTA_CONTROL);
      if (state == States.reconnecting) {
        var characteristic = event
            .firstWhere((element) => element.serviceUuid == UuidConsts.OTA_SERVICE)
            .characteristics
            .firstWhere((element) => element.characteristicUuid == UuidConsts.OTA_DATA);
        ctrlChar.write([0]).then((value) {
          setupMtuDivisible();
          pack = 0;
          pgss = 0;
          state = States.uploading;
          otaWriteDataReliable(characteristic, ctrlChar);
        });
      }
    });

    widget.device.connectionState.listen((event) {
      setState(() {
        connectionState = event;
      });

      if (event == BluetoothConnectionState.connected) {
        if (Platform.isAndroid) {
          widget.device.requestMtu(255);
        }
        Future.delayed(const Duration(milliseconds: 1000), () {
          widget.device.discoverServices();
        });
      }
    });

    widget.device.mtu.listen((event) {
      setState(() {
        mtu = event;
      });
    });
  }

  List<Widget> _buildServiceTiles(BuildContext context, List<BluetoothService> services) {
    return services
        .map(
          (s) => ServiceTile(
            service: s,
            characteristicTiles: s.characteristics
                .map(
                  (c) => CharacteristicTile(
                    characteristic: c,
                    onReadPressed: () async {
                      try {
                        await c.read();
                      } catch (e) {
                        final snackBar = SnackBar(content: Text(prettyException("Read Error:", e)));
                        snackBarKeyC.currentState?.showSnackBar(snackBar);
                      }
                    },
                    onWritePressed: (val) async {
                      try {
                        await c.write(utf8.encode(val), withoutResponse: c.properties.writeWithoutResponse);
                        if (c.properties.read) {
                          await c.read();
                        }
                      } catch (e) {
                        final snackBar = SnackBar(content: Text(prettyException("Write Error:", e)));
                        snackBarKeyC.currentState?.showSnackBar(snackBar);
                      }
                    },
                    onNotificationPressed: () async {
                      try {
                        await c.setNotifyValue(c.isNotifying == false);
                        if (c.properties.read) {
                          await c.read();
                        }
                      } catch (e) {
                        final snackBar = SnackBar(content: Text(prettyException("Subscribe Error:", e)));
                        snackBarKeyC.currentState?.showSnackBar(snackBar);
                      }
                    },
                    descriptorTiles: c.descriptors
                        .map(
                          (d) => DescriptorTile(
                            descriptor: d,
                            onReadPressed: () async {
                              try {
                                await d.read();
                              } catch (e) {
                                final snackBar = SnackBar(content: Text(prettyException("Read Error:", e)));
                                snackBarKeyC.currentState?.showSnackBar(snackBar);
                              }
                            },
                            onWritePressed: () async {
                              try {
                                await d.write(_getRandomBytes());
                              } catch (e) {
                                final snackBar = SnackBar(content: Text(prettyException("Write Error:", e)));
                                snackBarKeyC.currentState?.showSnackBar(snackBar);
                              }
                            },
                          ),
                        )
                        .toList(),
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  void setupMtuDivisible() {
    int minus = 0;
    do {
      mtuDivisible = mtu - 3 - minus;
      minus++;
    } while (mtuDivisible % 4 != 0);
  }

  void otaWriteDataReliable(BluetoothCharacteristic char, BluetoothCharacteristic ctrl) {
    Uint8List writearray;
    if (pack + mtuDivisible > data.length - 1) {
      /**SET last by 4 */
      var plus = 0;
      var last = data.length - pack;
      do {
        last += plus;
        plus++;
      } while (last % 4 != 0);
      writearray = Uint8List(last);
      for (var j = 0, i = pack; i < pack + last; j++, i++) {
        if (data.length - 1 < i) {
          writearray[j] = 0xFF;
        } else {
          writearray[j] = data[i];
        }
      }
      setState(() {
        pgss = ((pack + last) / (data.length - 1)) * 100;
      });
    } else {
      var j = 0;
      writearray = Uint8List(mtuDivisible);
      for (var i = pack; i < pack + mtuDivisible; i++) {
        writearray[j] = data[i];
        j++;
      }
      setState(() {
        pgss = ((pack + mtuDivisible) / (data.length - 1)) * 100;
      });
    }

    char.write(writearray, withoutResponse: false).then((value) {
      handleResponse(char, ctrl);
    });

    num waitingTime = (DateTime.now().millisecondsSinceEpoch - otatime);

    setState(() {
      bitrate = 8 * pack / waitingTime.toDouble();
    });

    if (pack <= 0) {
      otatime = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void handleResponse(BluetoothCharacteristic dataChar, BluetoothCharacteristic control) {
    pack += mtuDivisible;
    if (pack <= data.length - 1) {
      otaWriteDataReliable(dataChar, control);
    } else if (pack > data.length - 1) {
      control.write([0x03]).then((value) {
        widget.device.disconnect().then((value) {
          Future.delayed(const Duration(milliseconds: 4000), () async {
            await widget.device.connect();
          });
        });
      });
    }
  }

  int getIntFromBytes(List<int> bytes) {
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  DateTime? getDateFromBytes(List<int> bytes) {
    if (bytes.length != 36) {
      return null;
    }
    int sec = getIntFromBytes(bytes.sublist(0, 4).reversed.toList());
    int min = getIntFromBytes(bytes.sublist(4, 8).reversed.toList());
    int hour = getIntFromBytes(bytes.sublist(8, 12).reversed.toList());
    int day = getIntFromBytes(bytes.sublist(12, 16).reversed.toList());
    int mon = getIntFromBytes(bytes.sublist(16, 20).reversed.toList()) + 1;
    int year = getIntFromBytes(bytes.sublist(20, 24).reversed.toList()) + 1900;
    int wday = getIntFromBytes(bytes.sublist(24, 28).reversed.toList());
    int yday = getIntFromBytes(bytes.sublist(28, 32).reversed.toList());
    int isdst = getIntFromBytes(bytes.sublist(32, 36).reversed.toList());

    return DateTime(year, mon, day, hour, min, sec);
  }

  List<int> intToBytes(int value) {
    List<int> bytes = [];
    bytes.add((value >> 24) & 0xFF);
    bytes.add((value >> 16) & 0xFF);
    bytes.add((value >> 8) & 0xFF);
    bytes.add(value & 0xFF);
    return bytes.reversed.toList();
  }

  List<int> dateTimeToBytes() {
    DateTime dateTime = DateTime.now();
    List<int> bytes = [];
    bytes.addAll(intToBytes(dateTime.second));
    bytes.addAll(intToBytes(dateTime.minute));
    bytes.addAll(intToBytes(dateTime.hour));
    bytes.addAll(intToBytes(dateTime.day));
    bytes.addAll(intToBytes(dateTime.month));
    bytes.addAll(intToBytes(dateTime.year));
    bytes.addAll(List<int>.generate(12, (index) => 0));

    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    VoidCallback? onPressed;
    String text;

    switch (connectionState) {
      case BluetoothConnectionState.connected:
        onPressed = () async {
          try {
            await widget.device.disconnect();
          } catch (e) {
            final snackBar = SnackBar(content: Text(prettyException("Disconnect Error:", e)));
            snackBarKeyC.currentState?.showSnackBar(snackBar);
          }
        };

        text = 'DISCONNECT';
        break;
      case BluetoothConnectionState.disconnected:
        onPressed = () async {
          try {
            await widget.device.connect(timeout: const Duration(seconds: 4));
          } catch (e) {
            final snackBar = SnackBar(content: Text(prettyException("Connect Error:", e)));
            snackBarKeyC.currentState?.showSnackBar(snackBar);
          }
        };
        text = 'CONNECT';
        break;
      default:
        onPressed = null;
        text = connectionState.toString().split(".").last.toUpperCase();
        break;
    }
    return ScaffoldMessenger(
      key: snackBarKeyC,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.device.localName),
          actions: <Widget>[
            TextButton(
                onPressed: onPressed,
                child: Text(
                  text,
                  style: Theme.of(context).primaryTextTheme.labelLarge?.copyWith(color: Colors.white),
                ))
          ],
        ),
        body: SingleChildScrollView(
          child: Column(
            children: <Widget>[
              ListTile(
                title: const Text('MTU Size'),
                subtitle: Text('$mtu bytes'),
                trailing: IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () async {
                      try {
                        await widget.device.requestMtu(223);
                      } catch (e) {
                        final snackBar = SnackBar(content: Text(prettyException("Change Mtu Error:", e)));
                        snackBarKeyC.currentState?.showSnackBar(snackBar);
                      }
                    }),
              ),
              (time != null)
                  ? ListTile(
                      title: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('Time on hardware'),
                        Text(
                          (current_time == null) ? '' : DateFormat('HH:mm:ss').format(current_time!),
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).textTheme.bodySmall?.color),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text('Time on device'),
                              Text(
                                DateFormat('HH:mm:ss').format(DateTime.now()),
                                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).textTheme.bodySmall?.color),
                              )
                            ],
                          ),
                        ),
                        if (time!.properties.write)
                          Row(
                            children: <Widget>[
                              if (time!.properties.read)
                                TextButton(
                                    child: const Text("Read"),
                                    onPressed: () async {
                                      try {
                                        await time!.read();
                                      } catch (e) {
                                        final snackBar = SnackBar(content: Text(prettyException("Read Error:", e)));
                                        snackBarKeyC.currentState?.showSnackBar(snackBar);
                                      }
                                    }),
                              if (time!.properties.write)
                                TextButton(
                                    child: const Text("Sync"),
                                    onPressed: () async {
                                      try {
                                        await time!.write(dateTimeToBytes());
                                      } catch (e) {
                                        final snackBar = SnackBar(content: Text(prettyException("Subscribe Error:", e)));
                                        snackBarKeyC.currentState?.showSnackBar(snackBar);
                                      }
                                    }),
                              if (time!.properties.notify || time!.properties.indicate)
                                TextButton(
                                    child: Text(time!.isNotifying ? "Unsubscribe" : "Subscribe"),
                                    onPressed: () async {
                                      try {
                                        await time!.setNotifyValue(time!.isNotifying == false);
                                        if (time!.properties.read) {
                                          await time!.read();
                                        }
                                      } catch (e) {
                                        final snackBar = SnackBar(content: Text(prettyException("Subscribe Error:", e)));
                                        snackBarKeyC.currentState?.showSnackBar(snackBar);
                                      }
                                    })
                            ],
                          ),
                      ],
                    ))
                  : const Text("Time not found"),
              Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async {
                            FilePickerResult? result = await FilePicker.platform.pickFiles();
                            if (result != null) {
                              File otaFile = File(result.files.single.path!);
                              data = otaFile.readAsBytesSync();
                            }
                          },
                          child: const Text('Select OTA')),
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async {
                            var characteristic = widget.device.servicesList
                                ?.firstWhere((element) => element.serviceUuid == UuidConsts.OTA_SERVICE)
                                .characteristics
                                .firstWhere((element) => element.characteristicUuid == UuidConsts.OTA_CONTROL);
                            Future.delayed(const Duration(milliseconds: 4000), () async {
                              await widget.device.connect();
                            });
                            state = States.reconnecting;
                            characteristic?.write([0], withoutResponse: false);
                          },
                          child: const Text('Upload')),
                    ],
                  )
                ],
              ),
              Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(padding: const EdgeInsets.all(10), child: Text("${pgss.toStringAsFixed(2)}%")),
                      Padding(padding: const EdgeInsets.all(10), child: Text("${bitrate.toStringAsFixed(2)} kbit/s")),
                    ],
                  )
                ],
              ),
              LinearProgressIndicator(
                value: pgss / 100,
              ),
              Column(children: _buildServiceTiles(context, list)),
            ],
          ),
        ),
      ),
    );
  }
}
