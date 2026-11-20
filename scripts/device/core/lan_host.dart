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

/// The Local Network prompt wait of `--prompt-wait-minutes`: [raw] is the option's text (or `null`, the
/// default of 3 minutes). A value that is not a whole number from 1 to 240 is an error, never a silent default.
({Duration? wait, String? problem}) parsePromptWait(String? raw) {
  if (raw == null) return (wait: const Duration(minutes: 3), problem: null);
  final n = int.tryParse(raw);
  if (n == null || n < 1 || n > 240) {
    return (
      wait: null,
      problem:
          '--prompt-wait-minutes must be a whole number from 1 to 240, got "$raw"',
    );
  }
  return (wait: Duration(minutes: n), problem: null);
}

/// `--prompt-wait-minutes` from the command line: absent keeps the default, but a flag given without an
/// operand (last argument, or followed by another `--option`) is an error, never the default.
({Duration? wait, String? problem}) parsePromptWaitArgs(List<String> args) {
  const flag = '--prompt-wait-minutes';
  final i = args.indexOf(flag);
  if (i < 0) return parsePromptWait(null);
  if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
    return (wait: null, problem: '$flag needs a number of minutes');
  }
  return parsePromptWait(args[i + 1]);
}
