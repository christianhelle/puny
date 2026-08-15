const types = @import("types.zig");
const validate = @import("validate.zig");
const index = @import("index.zig");
const query = @import("query.zig");

pub const SessionInfo = types.SessionInfo;
pub const dupeSessionInfo = types.dupeSessionInfo;
pub const lessThan = types.lessThan;

pub const isValidSessionId = validate.isValidSessionId;
pub const truncateFirstPrompt = validate.truncateFirstPrompt;

pub const sessionsPath = index.sessionsPath;
pub const listSessions = index.listSessions;
pub const upsertSessionInfo = index.upsertSessionInfo;
pub const removeSessionFromIndex = index.removeSessionFromIndex;
pub const pruneSessions = index.pruneSessions;

pub const findSessionByPrefix = query.findSessionByPrefix;
pub const findLatestSession = query.findLatestSession;