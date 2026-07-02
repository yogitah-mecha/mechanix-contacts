enum PhoneLabel { mobile, home, work, main, fax, other }

enum EmailLabel { home, work, personal, school, other }

enum ContactsStatus { initial, loading, loaded, error }

enum ContactsError {
  loadFailed,
  saveFailed,
  deleteFailed,
  storeUnavailable,
  unknown,
  updateFailed,
  searchFailed,
  duplicateContact,
}
