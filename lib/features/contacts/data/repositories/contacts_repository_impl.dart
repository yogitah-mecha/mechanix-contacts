import 'package:mechanix_contacts/features/contacts/data/models/contacts.dart';
import 'package:mechanix_contacts/features/contacts/data/models/email.dart';
import 'package:mechanix_contacts/features/contacts/data/models/phone_numbers.dart';
import 'package:mechanix_contacts/features/contacts/data/models/sim_card.dart';
import 'package:mechanix_contacts/features/contacts/services/contacts_store_service.dart';
import 'package:mechanix_contacts/objectbox.g.dart';
import 'package:mechanix_contacts/core/exceptions/app_exception.dart';
import '../../../../core/utils/app_logger.dart';
import 'contacts_repository.dart';

class ContactsRepositoryImpl implements ContactsRepository {
  final Store? _store;
  final Box<ContactEntity>? _contactsBox;
  final Box<PhoneNumberEntity>? _phoneNumbersBox;
  final Box<EmailEntity>? _emailsBox;
  final Box<SimCardEntity>? _simsBox;

  ContactsRepositoryImpl({Store? store})
    : _store = store,
      _contactsBox = store?.box<ContactEntity>(),
      _phoneNumbersBox = store?.box<PhoneNumberEntity>(),
      _emailsBox = store?.box<EmailEntity>(),
      _simsBox = store?.box<SimCardEntity>();

  Store get _activeStore => _store ?? ContactsStoreService.store;
  Box<ContactEntity> get _contacts =>
      _contactsBox ?? ContactsStoreService.contacts;
  Box<PhoneNumberEntity> get _phoneNumbers =>
      _phoneNumbersBox ?? ContactsStoreService.phoneNumbers;
  Box<EmailEntity> get _emails => _emailsBox ?? ContactsStoreService.emails;
  Box<SimCardEntity> get _sims => _simsBox ?? ContactsStoreService.sims;

  Future<void> _ensureConnected() async {
    try {
      if (_store == null) {
        await ContactsStoreService.ensureConnected();
      }
    } catch (e, stackTrace) {
      AppLogger.e('Failed to connect to contacts store: $e', stack: stackTrace);
      rethrow;
    }
  }

  @override
  Future<List<ContactEntity>> getAll() async {
    try {
      await _ensureConnected();

      final query = _contacts.query().order(ContactEntity_.name).build();

      try {
        return query.find();
      } finally {
        query.close();
      }
    } catch (e, stackTrace) {
      AppLogger.e('Failed to get contacts: $e', stack: stackTrace);
      rethrow;
    }
  }

  @override
  Future<ContactEntity?> getById(int id) async {
    try {
      await _ensureConnected();
      return _contacts.get(id);
    } catch (e, stackTrace) {
      AppLogger.e('Failed to get contact by id $id: $e', stack: stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> save(
    ContactEntity contact,
    List<String> numbers,
    List<String>? emails,
  ) async {
    try {
      await _ensureConnected();

      _activeStore.runInTransaction(TxMode.write, () {
        // Check for duplicates: same name (case-insensitive) and same number (digits only match)
        final sameNameContacts = _contacts
            .query(
              ContactEntity_.name.equals(contact.name, caseSensitive: false),
            )
            .build()
            .find();

        final otherContacts = sameNameContacts
            .where((c) => c.id != contact.id)
            .toList();

        if (otherContacts.isNotEmpty) {
          final otherContactIds = otherContacts.map((c) => c.id).toList();
          final builder = _phoneNumbers.query();

          builder.link(
            PhoneNumberEntity_.contact,
            ContactEntity_.id.oneOf(otherContactIds),
          );

          final matchingPhoneNumbers = builder.build().find();

          final newNumbersNormalized = numbers
              .map((n) => n.replaceAll(RegExp(r'\D'), ''))
              .where((n) => n.isNotEmpty)
              .toSet();

          for (final existingPhone in matchingPhoneNumbers) {
            final existingNormalized = existingPhone.number.replaceAll(
              RegExp(r'\D'),
              '',
            );
            if (newNumbersNormalized.contains(existingNormalized)) {
              throw const DuplicateContactException();
            }
          }
        }

        // If editing, clear existing numbers, emails of this contact first
        if (contact.id != 0) {
          final existingNumbers = _phoneNumbers
              .query(PhoneNumberEntity_.contact.equals(contact.id))
              .build()
              .find();
          _phoneNumbers.removeMany(existingNumbers.map((n) => n.id).toList());

          final existingEmails = _emails
              .query(EmailEntity_.contact.equals(contact.id))
              .build()
              .find();
          _emails.removeMany(existingEmails.map((e) => e.id).toList());
        }

        // Save contact first to get an ID
        _contacts.put(contact);

        // Save new phone numbers
        for (final numStr in numbers) {
          if (numStr.trim().isEmpty) continue;
          final phone = PhoneNumberEntity(number: numStr.trim());
          phone.contact.target = contact;
          _phoneNumbers.put(phone);
        }

        final uniqueEmails = (emails ?? [])
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();

        for (final emailStr in uniqueEmails) {
          final email = EmailEntity(email: emailStr);
          email.contact.target = contact;
          _emails.put(email);
        }
      });
    } catch (e, stackTrace) {
      AppLogger.e('Failed to save contact: $e', stack: stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> delete(int id) async {
    try {
      await _ensureConnected();
      _activeStore.runInTransaction(TxMode.write, () {
        // Remove all phone numbers, emails for this contact first
        final existingNumbers = _phoneNumbers
            .query(PhoneNumberEntity_.contact.equals(id))
            .build()
            .find();
        _phoneNumbers.removeMany(existingNumbers.map((n) => n.id).toList());

        final existingEmails = _emails
            .query(EmailEntity_.contact.equals(id))
            .build()
            .find();
        _emails.removeMany(existingEmails.map((e) => e.id).toList());
        // Then remove the contact
        _contacts.remove(id);
      });
    } catch (e, stackTrace) {
      AppLogger.e('Failed to delete contact $id: $e', stack: stackTrace);
      rethrow;
    }
  }

  @override
  Future<List<ContactEntity>> search(String queryStr) async {
    await _ensureConnected();

    if (queryStr.trim().isEmpty) {
      return getAll();
    }

    // Find all contact IDs that have matching phone numbers
    final matchingPhoneNumbers = _phoneNumbers
        .query(PhoneNumberEntity_.number.contains(queryStr))
        .build()
        .find();
    final contactIdsFromNumbers = matchingPhoneNumbers
        .map((p) => p.contact.targetId)
        .where((id) => id != 0)
        .toSet();

    // Find all contacts that match name OR have matching phone numbers
    final Condition<ContactEntity> cond;
    if (contactIdsFromNumbers.isNotEmpty) {
      cond = ContactEntity_.name
          .contains(queryStr, caseSensitive: false)
          .or(ContactEntity_.id.oneOf(contactIdsFromNumbers.toList()));
    } else {
      cond = ContactEntity_.name.contains(queryStr, caseSensitive: false);
    }

    final query = _contacts.query(cond).order(ContactEntity_.name).build();

    try {
      return query.find();
    } catch (e, stackTrace) {
      AppLogger.e(
        'Failed to search contacts with query "$queryStr": $e',
        stack: stackTrace,
      );
      rethrow;
    } finally {
      query.close();
    }
  }

  @override
  Future<List<SimCardEntity>> getSimCards() async {
    try {
      await _ensureConnected();
      final count = _sims.count();
      if (count == 0) {
        // TODO: Remove this logic once actual SIM card data is available
        _activeStore.runInTransaction(TxMode.write, () {
          _sims.put(
            SimCardEntity(slot: '1', name: 'Primary', number: '01-554738'),
          );
          _sims.put(
            SimCardEntity(slot: '2', name: 'Secondary', number: '01-626262'),
          );
        });
      }
      return _sims.getAll();
    } catch (e, stackTrace) {
      AppLogger.e('Failed to get SIM cards: $e', stack: stackTrace);
      rethrow;
    }
  }
}
