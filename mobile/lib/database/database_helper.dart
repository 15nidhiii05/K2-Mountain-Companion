import 'package:sqflite/sqflite.dart';

/// Local on-device storage. This is a cache and offline fallback only; the
/// FastAPI server is the source of truth when it is reachable.
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  static Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      '$dir/k2_local.db',
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            password TEXT NOT NULL DEFAULT '',
            height INTEGER DEFAULT 0,
            weight INTEGER DEFAULT 0,
            blood_group TEXT DEFAULT '',
            created_at TEXT
          )''');
        await db.execute('''
          CREATE TABLE emergency_contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER,
            name TEXT,
            phone_number TEXT,
            relationship TEXT
          )''');
        await db.execute('''
          CREATE TABLE water_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER,
            amount REAL,
            timestamp TEXT
          )''');
        await db.execute('''
          CREATE TABLE treks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER,
            trek_name TEXT,
            start_date TEXT,
            end_date TEXT,
            distance REAL,
            max_altitude INTEGER,
            status TEXT
          )''');
      },
    );
    _db = db;
    return db;
  }

  // ---- users
  Future<int> insertUser(Map<String, dynamic> row) async {
    final db = await database;
    return db.insert(
      'users',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getUsers() async {
    final db = await database;
    return db.query('users');
  }

  // ---- emergency contacts
  Future<int> insertEmergencyContact(Map<String, dynamic> row) async {
    final db = await database;
    return db.insert('emergency_contacts', row);
  }

  Future<List<Map<String, dynamic>>> getEmergencyContacts() async {
    final db = await database;
    return db.query('emergency_contacts', orderBy: 'id');
  }

  // ---- water
  Future<int> insertWater(Map<String, dynamic> row) async {
    final db = await database;
    return db.insert('water_logs', row);
  }

  // ---- treks
  Future<int> insertTrek(Map<String, dynamic> row) async {
    final db = await database;
    return db.insert('treks', row);
  }

  Future<List<Map<String, dynamic>>> getTreks() async {
    final db = await database;
    return db.query('treks', orderBy: 'start_date DESC');
  }
}
