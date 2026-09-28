import Foundation
import OpenClawCore
import OpenClawGateway
import OpenClawProtocol

/// Registers the in-process `cron.*` gateway methods over a ``CronScheduler``.
///
/// - `cron.status` → `{enabled, running, jobs, enabledJobs, nextWakeAtMs, storePath}`
/// - `cron.list {includeDisabled?, limit?, offset?, query?, agentId?}` → `{jobs, total, offset, limit, hasMore, nextOffset?}`
/// - `cron.get {id|jobId}` → job
/// - `cron.add {…job}` → job (unsupported schedule/payload kinds are `INVALID_REQUEST`)
/// - `cron.update {id|jobId, patch}` → job
/// - `cron.remove {id|jobId}` → `{ok, removed}`
/// - `cron.run {id|jobId, mode?: due|force|if-enabled}` → `{ok, ran, run?}`
/// - `cron.runs {id|jobId?, limit?, offset?}` → `{entries}`
/// - `cron.scratch.get` / `cron.scratch.set` → `UNAVAILABLE`
///
/// Every mutation also broadcasts the upstream `cron` event through the request's event emitter.
/// - Parameters:
///   - registrar: Gateway server or registrar.
///   - scheduler: Scheduler.
public func registerCronGatewayMethods(on registrar: some GatewayMethodRegistrar, scheduler: CronScheduler) async {
    await registrar.register(method: "cron.status") { _ in
        let status = await scheduler.status()
        var object = try AnyCodable(encoding: status).dictionaryValue ?? [:]
        object["enabled"] = AnyCodable(true)
        return AnyCodable(object)
    }
    await registrar.register(method: "cron.list") { request in
        let params = request.params
        let includeDisabled = params["includeDisabled"]?.boolValue ?? false
        let limit = min(200, max(1, params["limit"]?.intValue ?? 50))
        let offset = max(0, params["offset"]?.intValue ?? 0)
        let query = params["query"]?.stringValue?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agentID = params["agentId"]?.stringValue
        var jobs = await scheduler.automationJobList(includeDisabled: includeDisabled)
        if !query.isEmpty {
            jobs = jobs.filter { $0.name.lowercased().contains(query) || ($0.description ?? "").lowercased().contains(query) || $0.id == query }
        }
        if let agentID {
            jobs = jobs.filter { ($0.agentId ?? "main") == agentID }
        }
        let page = Array(jobs.dropFirst(offset).prefix(limit))
        var result: [String: AnyCodable] = [
            "jobs": try AnyCodable(encoding: page),
            "total": AnyCodable(jobs.count),
            "offset": AnyCodable(offset),
            "limit": AnyCodable(limit),
            "hasMore": AnyCodable(offset + page.count < jobs.count),
        ]
        if offset + page.count < jobs.count { result["nextOffset"] = AnyCodable(offset + page.count) }
        return AnyCodable(result)
    }
    await registrar.register(method: "cron.get") { request in
        let id = try CronGatewaySupport.jobID(request)
        guard let job = await scheduler.automationJob(id: id) else {
            throw CronGatewaySupport.notFound(id)
        }
        return try AnyCodable(encoding: job)
    }
    await registrar.register(method: "cron.add") { request in
        let job: AutomationJob
        do {
            job = try AutomationJobDraft.job(from: request.params, sessionKey: request.params["sessionKey"]?.stringValue, agentID: nil)
            let added = try await scheduler.addJob(job)
            await CronGatewaySupport.emit(request, action: "added", job: added)
            return try AnyCodable(encoding: added)
        } catch let error as OpenClawCoreError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
    }
    await registrar.register(method: "cron.update") { request in
        let id = try CronGatewaySupport.jobID(request)
        guard let existing = await scheduler.automationJob(id: id) else {
            throw CronGatewaySupport.notFound(id)
        }
        do {
            let patched = try AutomationJobDraft.apply(patch: request.params["patch"]?.dictionaryValue ?? [:], to: existing)
            let updated = try await scheduler.updateJob(id: id) { $0 = patched }
            await CronGatewaySupport.emit(request, action: "updated", job: updated)
            return try AnyCodable(encoding: updated)
        } catch let error as OpenClawCoreError {
            throw GatewayMethodError.invalidRequest(error.localizedDescription)
        }
    }
    await registrar.register(method: "cron.remove") { request in
        let id = try CronGatewaySupport.jobID(request)
        let removed = try await scheduler.removeJob(id: id)
        if removed {
            await request.events.emit(.cron, payload: AnyCodable(["action": AnyCodable("removed"), "jobId": AnyCodable(id)]))
        }
        return AnyCodable(["ok": AnyCodable(true), "removed": AnyCodable(removed)])
    }
    await registrar.register(method: "cron.run") { request in
        let id = try CronGatewaySupport.jobID(request)
        guard let job = await scheduler.automationJob(id: id) else {
            throw CronGatewaySupport.notFound(id)
        }
        let mode = request.params["mode"]?.stringValue ?? "due"
        guard ["due", "force", "if-enabled"].contains(mode) else {
            throw GatewayMethodError.invalidRequest("mode must be due, force or if-enabled")
        }
        if mode == "if-enabled", !job.enabled {
            return AnyCodable(["ok": AnyCodable(true), "ran": AnyCodable(false), "reason": AnyCodable("disabled")])
        }
        guard let record = try await scheduler.runJob(id: id, force: mode != "due") else {
            return AnyCodable(["ok": AnyCodable(true), "ran": AnyCodable(false), "reason": AnyCodable("not-due")])
        }
        await request.events.emit(.cron, payload: try AnyCodable(encoding: record))
        return AnyCodable(["ok": AnyCodable(true), "ran": AnyCodable(true), "run": try AnyCodable(encoding: record)])
    }
    await registrar.register(method: "cron.runs") { request in
        let params = request.params
        let id = params["id"]?.stringValue ?? params["jobId"]?.stringValue
        if let id, id.contains("/") || id.contains("\\") {
            throw GatewayMethodError.invalidRequest("invalid job id")
        }
        let limit = min(200, max(1, params["limit"]?.intValue ?? 50))
        let offset = max(0, params["offset"]?.intValue ?? 0)
        let entries = await scheduler.runs(jobID: id, limit: limit, offset: offset)
        return AnyCodable(["entries": try AnyCodable(encoding: entries)])
    }
    for method in ["cron.scratch.get", "cron.scratch.set"] {
        await registrar.register(method: method) { request in
            throw GatewayMethodError.unavailable("\(request.method) is not available in the embedded scheduler")
        }
    }
}

enum CronGatewaySupport {
    static func jobID(_ request: GatewayMethodRequest) throws -> String {
        guard let id = request.stringParam("id", "jobId") else {
            throw GatewayMethodError.invalidRequest("\(request.method) requires id or jobId")
        }
        return id
    }

    static func notFound(_ id: String) -> GatewayMethodError {
        GatewayMethodError.invalidRequest("cron job not found: \(id)", details: AnyCodable(["code": AnyCodable("CRON_JOB_NOT_FOUND"), "jobId": AnyCodable(id)]))
    }

    static func emit(_ request: GatewayMethodRequest, action: String, job: AutomationJob) async {
        let payload = AnyCodable([
            "action": AnyCodable(action),
            "jobId": AnyCodable(job.id),
            "job": (try? AnyCodable(encoding: job)) ?? AnyCodable.nullValue,
        ])
        await request.events.emit(.cron, payload: payload)
    }
}
