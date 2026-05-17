enum DlcParty {
  offerer,
  acceptor;

  static DlcParty parse(String value) {
    switch (value) {
      case 'offerer':
        return DlcParty.offerer;
      case 'acceptor':
        return DlcParty.acceptor;
      default:
        throw ArgumentError("Invalid party: $value. Must be 'offerer' or 'acceptor'");
    }
  }
}
