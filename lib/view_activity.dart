import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:intl/intl.dart';
import 'package:silicon_labs/hardware_config_activity.dart';
import 'package:silicon_labs/models/hardware_config.dart';

import 'utils/snackbar.dart';
import 'widgets/characteristic_tile.dart';
import 'widgets/descriptor_tile.dart';
import 'widgets/service_tile.dart';
import 'package:collection/collection.dart';

final snackBarKeyA = GlobalKey<ScaffoldMessengerState>();
final snackBarKeyB = GlobalKey<ScaffoldMessengerState>();
final snackBarKeyC = GlobalKey<ScaffoldMessengerState>();

class UuidConsts {
  static final OTA_SERVICE = Guid("1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0");
  static final OTA_CONTROL = Guid("f7bf3564-fb6d-4e53-88a4-5e37e0326063");
  static final OTA_DATA = Guid("984227f3-34fc-4045-a5d0-2c581f81a153");
  static final TIME = Guid("b8470d55-e009-41ff-a648-817e4488ba57");
  static final BLINKY_SERVICE = Guid("de8a5aac-a99b-c315-0c80-60d4cbb51224");
  static final WRITE_DATA_CONTROL = Guid("dc425463-1d21-4a71-b12c-61578c98ea6c");
  static final WRITE_DATA = Guid("9efadae4-96d0-4839-86e4-16d9db763932");
  static final REQUEST_CONFIG = Guid("cc10d20a-c4ec-47e2-a41e-eea7a80a985b");
}

enum States { idle, reconnecting, uploading, finalised }

class ViewActivity extends StatefulWidget {
  const ViewActivity({Key? key, required this.device}) : super(key: key);

  final BluetoothDevice device;

  @override
  State<StatefulWidget> createState() => _ViewActivityState();
}

class _ViewActivityState extends State<ViewActivity> {
  List<HardwareConfig> hardwareConfigs = [];
  Uint8List data = Uint8List(0);
  var mtu = 255;
  var state = States.idle;
  var mtuDivisible = 0;
  var pack = 0;
  var otatime = 0;
  var mtuListner;
  var connectionListner;
  double pgss = 0;
  double bitrate = 0;
  BluetoothConnectionState connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> list = [];
  BluetoothCharacteristic? time, write_data_control, write_data, requestConfig;
  DateTime? currentTime;

  List<int> _getRandomBytes() {
    final math = Random();
    return [math.nextInt(255), math.nextInt(255), math.nextInt(255), math.nextInt(255)];
  }

  @override
  void initState() {
    super.initState();

    int year = 2024; // Leap year

    for (int month = 1; month <= 12; month++) {
      int daysInMonth = DateTime(year, month + 1, 0).day;

      for (int day = 1; day <= daysInMonth; day++) {
        DateTime date = DateTime(year, month, day);
        for (int hour = 1; hour <= 24; hour++) {
          hardwareConfigs.add(HardwareConfig(hour, date.day, date.month, Random().nextInt(901) + 100));
        }
      }
    }

    connectionListner = widget.device.connectionState.listen((event) {
      setState(() {
        connectionState = event;
      });

      if (event == BluetoothConnectionState.connected) {
        if (Platform.isAndroid) {
          widget.device.requestMtu(255);
        }
        Future.delayed(const Duration(milliseconds: 1000), () async {
          try {
            await widget.device.discoverServices();
          } catch (e) {}
          var event = widget.device.servicesList;
          setState(() {
            list = event;
            time = event
                .firstWhereOrNull((element) => element.serviceUuid == UuidConsts.BLINKY_SERVICE)
                ?.characteristics
                .firstWhereOrNull((element) => element.characteristicUuid == UuidConsts.TIME);
            write_data_control = event
                .firstWhereOrNull((element) => element.serviceUuid == UuidConsts.BLINKY_SERVICE)
                ?.characteristics
                .firstWhereOrNull((element) => element.characteristicUuid == UuidConsts.WRITE_DATA_CONTROL);

            write_data = event
                .firstWhereOrNull((element) => element.serviceUuid == UuidConsts.BLINKY_SERVICE)
                ?.characteristics
                .firstWhereOrNull((element) => element.characteristicUuid == UuidConsts.WRITE_DATA);

            requestConfig = event
                .firstWhereOrNull((element) => element.serviceUuid == UuidConsts.BLINKY_SERVICE)
                ?.characteristics
                .firstWhereOrNull((element) => element.characteristicUuid == UuidConsts.REQUEST_CONFIG);
          });

          if (time != null) {
            time!.onValueReceived.listen((event) {
              setState(() {
                currentTime = getDateFromBytes(event);
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
      } else {
        setState(() {
          list = [];
        });
      }
    });

    mtuListner = widget.device.mtu.listen((event) {
      setState(() {
        mtu = event;
      });
    });
  }

  @override
  void dispose() {
    if (mtuListner != null) {
      mtuListner.cancel();
    }

    if (connectionListner != null) {
      connectionListner.cancel();
    }

    super.dispose();
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

  Uint8List intListToUint8List(List<int> intList) {
    final uint8List = Uint8List(intList.length * 2);
    var index = 0;

    for (final intValue in intList) {
      uint8List[index++] = intValue & 0xFF; // Lower byte
      uint8List[index++] = (intValue >> 8) & 0xFF; // Higher byte
    }

    return uint8List;
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
            setState(() {
              list = [];
            });
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
          title: Text(widget.device.platformName),
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
                          (currentTime == null) ? '' : DateFormat('HH:mm:ss').format(currentTime!),
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
                                .firstWhere((element) => element.serviceUuid == UuidConsts.OTA_SERVICE)
                                .characteristics
                                .firstWhere((element) => element.characteristicUuid == UuidConsts.OTA_CONTROL);
                            Future.delayed(const Duration(milliseconds: 4000), () async {
                              await widget.device.connect();
                            });
                            state = States.reconnecting;
                            characteristic.write([0], withoutResponse: false);
                          },
                          child: const Text('Upload')),
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
                          onPressed: (write_data_control != null)
                              ? () => Navigator.of(context).push(MaterialPageRoute(
                                  builder: (context) => HardwareConfigActivity(
                                        list: hardwareConfigs,
                                        requestConfig: requestConfig!,
                                      ),
                                  settings: const RouteSettings(name: '/hardwareConfigs')))
                              : null,
                          child: const Text('Configurations')),
                      const SizedBox(width: 6),
                      ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: (write_data_control != null)
                              ? () async {
                                  try {
                                    DateTime startTime = DateTime.now();
                                    int bitsSent = 0;
                                    List<int> intList = hardwareConfigs.map((e) => e.value).toList();
                                    Uint8List uint16List = intListToUint8List(intList);
                                    await write_data_control!.write([0]);
                                    int groupSize = mtu;
                                    do {
                                      groupSize -= 1;
                                    } while (groupSize % 4 != 0);
                                    for (int i = 0; i < uint16List.length; i += groupSize) {
                                      var subData = uint16List.sublist(i, ((i + groupSize) > uint16List.length ? uint16List.length : i + groupSize));
                                      await write_data!.write(subData);
                                      bitsSent += subData.length * 8;
                                      DateTime currentTime = DateTime.now();
                                      Duration elapsedTime = currentTime.difference(startTime);
                                      double elapsedSeconds = elapsedTime.inMicroseconds.toDouble() / 1000000.0; // Convert to seconds
                                      setState(() {
                                        pgss = ((groupSize + i) / (uint16List.length)) * 100;
                                        bitrate = (bitsSent / elapsedSeconds) / 1000.0;
                                      });
                                    }
                                    await write_data_control!.write([0x01]);
                                  } catch (e) {
                                    final snackBar = SnackBar(content: Text(prettyException("Write Error:", e)));
                                    snackBarKeyC.currentState?.showSnackBar(snackBar);
                                  }
                                }
                              : null,
                          child: const Text('Write Config'))
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
              Container(
                margin: const EdgeInsets.only(top: 10),
                child: Column(children: _buildServiceTiles(context, list)),
              )
            ],
          ),
        ),
      ),
    );
  }
}
