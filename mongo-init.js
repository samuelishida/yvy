function readEnv(name, fallback = "") {
  if (typeof process !== "undefined" && process.env && process.env[name]) {
    return process.env[name];
  }
  if (typeof _getEnv === "function") {
    return _getEnv(name) || fallback;
  }
  return fallback;
}

const databaseName = readEnv("MONGO_DATABASE", "terrabrasilis_data");
const appUsername = readEnv("MONGO_APP_USERNAME");
const appPassword = readEnv("MONGO_APP_PASSWORD");
const readonlyUsername = readEnv("MONGO_READONLY_USERNAME");
const readonlyPassword = readEnv("MONGO_READONLY_PASSWORD");

db = db.getSiblingDB(databaseName);

function upsertUser(username, password, roles) {
  if (!username || !password) {
    print(`Skipping user creation because credentials for ${username || "unknown"} are missing.`);
    return;
  }

  if (db.getUser(username)) {
    print(`User ${username} already exists.`);
    return;
  }

  db.createUser({
    user: username,
    pwd: password,
    roles,
  });

  print(`Created MongoDB user ${username}.`);
}

upsertUser(appUsername, appPassword, [
  {
    role: "readWrite",
    db: databaseName,
  },
]);

upsertUser(readonlyUsername, readonlyPassword, [
  {
    role: "read",
    db: databaseName,
  },
]);

db.deforestation_data.createIndex({ lat: 1, lon: 1 });
db.deforestation_data.createIndex({ timestamp: 1 });
