abstract class AppException implements Exception {
  final String message;

  const AppException(this.message);

  @override
  String toString() => message;
}

class AppAlreadyRunningException extends AppException {
  const AppAlreadyRunningException([
    super.message = 'This app instance is already running.',
  ]);
}

class ContactsStoreInitializationException extends AppException {
  const ContactsStoreInitializationException([
    super.message = 'Failed to initialize contacts database.',
  ]);
}

class DuplicateContactException extends AppException {
  const DuplicateContactException([
    super.message = 'A contact with this name and phone number already exists.',
  ]);
}
