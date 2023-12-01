import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:silicon_labs/models/hardware_config.dart';
import 'package:silicon_labs/utils/snackbar.dart';

final snackBarKeyC = GlobalKey<ScaffoldMessengerState>();

class HardwareConfigActivity extends StatefulWidget {
  final List<HardwareConfig> list;
  final BluetoothCharacteristic requestConfig;

  const HardwareConfigActivity({Key? key, required this.list, required this.requestConfig}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _HardwareActivityStates();
}

class _HardwareActivityStates extends State<HardwareConfigActivity> {
  BluetoothCharacteristic? requestConfig;
  bool _isSearchVisible = false;
  String _searchText = '';
  var event;

  @override
  void initState() {
    super.initState();

    requestConfig = widget.requestConfig;
    requestConfig!.setNotifyValue(true);
    event = requestConfig!.onValueReceived.listen((event) {
      int day = getIntFromBytes(event.sublist(0, 2));
      int hour = getIntFromBytes(event.sublist(2, 4));
      int value = getIntFromBytes(event.sublist(4, 6));

      setState(() {
        var elem = widget.list.firstWhere((element) => element.wDay() == day && element.hour == hour);
        elem.hardwareValue = value;
      });
    });
  }

  @override
  void dispose() {
    event.cancel();
    super.dispose();
  }

  int getIntFromBytes(List<int> bytes) {
    return (bytes[1] << 8) | bytes[0];
  }

  List<int> intToBytes(int value) {
    List<int> bytes = [];
    bytes.add(value & 0xFF);
    bytes.add((value >> 8) & 0xFF);
    return bytes;
  }

  AppBar buildAppBar(BuildContext context) {
    return AppBar(
      title: _isSearchVisible
          ? Container(
              width: double.infinity,
              height: 40,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5)),
              child: Center(
                child: TextField(
                  onChanged: (value) {
                    setState(() {
                      _searchText = value;
                    });
                  },
                  autofocus: _isSearchVisible,
                  decoration: const InputDecoration(hintText: "Search by date...", prefixIcon: Icon(Icons.search), border: InputBorder.none),
                ),
              ),
            )
          : const Text('Day Configuration'),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          Navigator.of(context).pop();
        },
      ),
      actions: [
        IconButton(
          icon: Icon(_isSearchVisible ? Icons.close : Icons.search),
          onPressed: () {
            setState(() {
              _isSearchVisible = !_isSearchVisible;
              if (!_isSearchVisible) {
                _searchText = '';
              }
            });
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    List<HardwareConfig> list = widget.list.where((element) => element.parsedDate().toLowerCase().contains(_searchText.toLowerCase())).toList();
    return Scaffold(
      appBar: buildAppBar(context),
      body: ListView.builder(
        itemCount: list.length,
        itemBuilder: (BuildContext context, int index) {
          var config = list[index];

          // Apply search filter
          if (_isSearchVisible && _searchText.isNotEmpty && !config.parsedDate().toLowerCase().contains(_searchText.toLowerCase())) {
            return const SizedBox.shrink(); // Skip displaying this item
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Card(
              child: InkWell(
                onTap: () {
                  // Handle card tap here if needed
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Date: ${config.parsedDate()}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text('Device value: ${config.value}'),
                          Text('Hardware Value: ${config.hardwareValue ?? "-"}'),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                      child: Container(
                        alignment: Alignment.center,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(40),
                          ),
                          onPressed: () async {
                            try {
                              await requestConfig!.write([intToBytes(config.wDay()), intToBytes(config.hour)].expand((element) => element).toList());
                            } catch (e) {
                              final snackBar = SnackBar(content: Text(prettyException("Write Error:", e)));
                              ScaffoldMessenger.of(context).showSnackBar(snackBar);
                            }
                          },
                          child: const Text("Read"),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
