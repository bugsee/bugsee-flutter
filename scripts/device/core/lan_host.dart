// The address the mock API binds. A physical iPhone reaches the Mac only over the LAN, so the harness binds
// ONE address of the Mac and never all interfaces: nothing here may let `0.0.0.0` or `::` through, and a
// URL built from the host without brackets must stay valid (IPv4 only).
import 'dart:io';

/// Why [host] cannot be bound by the mock at all, or `null`: it must be one IP address, not a name and not
/// "every interface" (`0.0.0.0`, `::`).
String? bindHostProblem(String host) {
  final a = InternetAddress.tryParse(host);
  if (a == null) return '"$host" is not an IP address (a name is not accepted)';
  if (a.address == '0.0.0.0' || a.address == '::') {
    return '"$host" binds every interface: use one address';
  }
  return null;
}

/// Why [host] is no good for a PHYSICAL iPhone, or `null`: besides [bindHostProblem], the phone cannot reach a
/// loopback or multicast address, and the app's URLs are built without IPv6 brackets.
String? lanHostProblem(String host) {
  final base = bindHostProblem(host);
  if (base != null) return base;
  final a = InternetAddress(host);
  if (a.type != InternetAddressType.IPv4) {
    return '"$host" is not an IPv4 address (the app\'s URLs are built without brackets)';
  }
  if (a.isLoopback) {
    return '"$host" is a loopback address: a phone cannot reach it';
  }
  if (a.isMulticast) {
    return '"$host" is a multicast address';
  }
  return null;
}
