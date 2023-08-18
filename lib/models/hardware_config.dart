import 'package:intl/intl.dart';

class HardwareConfig {
  int hour;
  int day;
  int month;
  int value;
  int year = 2024;
  int? hardwareValue;

  HardwareConfig(this.hour, this.day, this.month, this.value);

  String parsedDate() {
    var parsedMonth = DateFormat.MMMM().format(DateTime(year, month, day));
    return '$parsedMonth $day ${hour.toString().padLeft(2, "0")}:00';
  }

  DateTime dateObj() {
   return DateTime(year, month, day);
  }

  int wDay() {
    return dateObj().difference(DateTime(year, 1, 1)).inDays + 1;
  }
}
