/*
 *  Copyright (C) 2001, 2002  Joshua Schrier (jschrier@mac.com),
 *                2004-2021 Ingmar Stein
 *  Released under the GNU GPL.  For more information, see the header file.
 */
//
//  MainViewController.swift
//  Monolingual
//
//  Created by Ingmar Stein on 13.07.14.
//
//

import Cocoa
import OSLog
import UserNotifications

enum MonolingualMode: Int {
	case languages = 0
	case architectures
}

struct ArchitectureInfo {
	let name: String
	let displayName: String
	let cpuType: cpu_type_t
	let cpuSubtype: cpu_subtype_t
}

func mach_task_self() -> mach_port_t {
	mach_task_self_
}

final class MainViewController: NSViewController, ProgressViewControllerDelegate, ProgressProtocol {
	@IBOutlet private var currentArchitecture: NSTextField!

	private var progressViewController: ProgressViewController?

	private var blocklist: [BlocklistEntry]?
	@objc dynamic var languages: [LanguageSetting]!
	@objc dynamic var architectures: [ArchitectureSetting]!

	private var mode: MonolingualMode = .languages
	private var processApplication: Root?
	private var processApplicationObserver: NSObjectProtocol?
	private var helperConnection: NSXPCConnection?
	private var progress: Progress?
	private var progressResetTimer: Timer?
	private var progressObserverToken: NSKeyValueObservation?

	private let sipProtectedLocations = ["/System", "/bin"]

	let logger = Logger()

	private lazy var xpcServiceConnection: NSXPCConnection = {
		let connection = NSXPCConnection(serviceName: "com.github.IngmarStein.Monolingual.XPCService")
		connection.remoteObjectInterface = NSXPCInterface(with: XPCServiceProtocol.self)
		connection.resume()
		return connection
	}()

	private var roots: [Root] {
		if let application = self.processApplication {
			return [application]
		} else {
			if let pref = UserDefaults.standard.array(forKey: "Roots") as? [[String: AnyObject]] {
				return pref.map { Root(dictionary: $0) }
			} else {
				return [Root]()
			}
		}
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}

	private func finishProcessing() {
		progressDidEnd(completed: true)
	}

	@IBAction func removeLanguages(_: AnyObject) {
		// Display a warning first
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
		alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
		alert.messageText = NSLocalizedString("Are you sure you want to remove these languages?", comment: "")
		alert.informativeText = NSLocalizedString("You will not be able to restore them without reinstalling macOS.", comment: "")
		alert.beginSheetModal(for: view.window!) { responseCode in
			if NSApplication.ModalResponse.alertSecondButtonReturn == responseCode {
				self.checkAndRemove()
			}
		}
	}

	@IBAction func removeArchitectures(_: AnyObject) {
		mode = .architectures

		log.open()

		let version = (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? "vUNKNOWN"
		log.message("Monolingual \(version) started\n")
		log.message("Removing architectures:")

		let archs = architectures.filter(\.enabled).map(\.name)
		for arch in archs {
			log.message(" \(arch)", timestamp: false)
		}

		log.message("\nModified files:\n")

		let numArchs = archs.count
		if numArchs == architectures.count {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("Removing all architectures will make macOS inoperable.", comment: "")
			alert.informativeText = NSLocalizedString("Please keep at least one architecture and try again.", comment: "")
			alert.beginSheetModal(for: view.window!, completionHandler: nil)
			log.close()
		} else if numArchs > 0 {
			// start things off if we have something to remove!
			let roots = roots

			let request = HelperRequest()
			request.doStrip = UserDefaults.standard.bool(forKey: "Strip")
			request.bundleBlocklist = Set<String>(blocklist!.filter(\.architectures).map(\.bundle))
			request.includes = roots.filter(\.architectures).map(\.path)
			request.excludes = roots.filter { !$0.architectures }.map(\.path) + sipProtectedLocations
			request.thin = archs

			for item in request.bundleBlocklist! {
				logger.info("Blocking \(item, privacy: .public)")
			}
			for include in request.includes! {
				logger.info("Adding root \(include, privacy: .public)")
			}
			for exclude in request.excludes! {
				logger.info("Excluding root \(exclude, privacy: .public)")
			}

			checkAndRunHelper(arguments: request)
		} else {
			log.close()
		}
	}

	func processed(file: String, size: Int, appName: String?) {
		if let progress = progress {
			let count = progress.userInfo[.fileCompletedCountKey] as? Int ?? 0
			progress.setUserInfoObject(count + 1, forKey: .fileCompletedCountKey)
			progress.setUserInfoObject(URL(fileURLWithPath: file, isDirectory: false), forKey: .fileURLKey)
			progress.setUserInfoObject(size, forKey: ProgressUserInfoKey.sizeDifference)
			if let appName = appName {
				progress.setUserInfoObject(appName, forKey: ProgressUserInfoKey.appName)
			}
			progress.completedUnitCount += Int64(size)

			// show the file progress even if it has zero bytes
			if size == 0 {
				progress.willChangeValue(forKey: #keyPath(Progress.completedUnitCount))
				progress.didChangeValue(forKey: #keyPath(Progress.completedUnitCount))
			}
		}
	}

	private func processProgress(file: URL, size: Int, appName: String?) {
		log.message("\(file.path): \(size)\n")

		let message: String
		if mode == .architectures {
			message = NSLocalizedString("Removing architecture from universal binary", comment: "")
		} else {
			// parse file name
			var lang: String?

			if mode == .languages {
				for pathComponent in file.pathComponents where (pathComponent as NSString).pathExtension == "lproj" {
					for language in self.languages {
						if language.folders.contains(pathComponent) {
							lang = language.displayName
							break
						}
					}
				}
			}
			if let app = appName, let lang = lang {
				message = String(format: NSLocalizedString("Removing language %@ from %@…", comment: ""), lang, app)
			} else if let lang = lang {
				message = String(format: NSLocalizedString("Removing language %@…", comment: ""), lang)
			} else {
				message = String(format: NSLocalizedString("Removing %@…", comment: ""), file.absoluteString)
			}
		}

		DispatchQueue.main.async {
			if let viewController = self.progressViewController {
				viewController.text = message
				viewController.file = file.path
				NSApp.setWindowsNeedUpdate(true)
			}

			self.progressResetTimer?.invalidate()
			self.progressResetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
				if let viewController = self.progressViewController {
					viewController.text = NSLocalizedString("Removing...", comment: "")
					viewController.file = ""
					NSApp.setWindowsNeedUpdate(true)
				}
			}
		}
	}

	func installHelper(reply: @escaping (Bool) -> Void) {
		let xpcService = xpcServiceConnection.remoteObjectProxyWithErrorHandler { error -> Void in
			self.logger.error("XPCService error: \(error.localizedDescription, privacy: .public)")
		} as? XPCServiceProtocol

		if let xpcService = xpcService {
			xpcService.installHelperTool { error in
				if let error = error {
					DispatchQueue.main.async {
						let alert = NSAlert()
						alert.alertStyle = .critical
						alert.messageText = error.localizedDescription
						alert.informativeText = error.localizedRecoverySuggestion ?? error.localizedFailureReason ?? " "
						alert.beginSheetModal(for: self.view.window!, completionHandler: nil)
						log.close()
					}
					reply(false)
				} else {
					reply(true)
				}
			}
		}
	}

	private func runHelper(_ helper: HelperProtocol, arguments: HelperRequest) {
		ProcessInfo.processInfo.disableSuddenTermination()

		let helperProgress = Progress(totalUnitCount: -1)
		helperProgress.becomeCurrent(withPendingUnitCount: -1)
		progressObserverToken = helperProgress.observe(\.completedUnitCount) { progress, _ in
			if let url = progress.fileURL, let size = progress.userInfo[ProgressUserInfoKey.sizeDifference] as? Int {
				self.processProgress(file: url, size: size, appName: progress.userInfo[ProgressUserInfoKey.appName] as? String)
			}
		}

		// DEBUG
		// arguments.dryRun = true

		helper.process(request: arguments, progress: self) { exitCode in
			self.logger.info("helper finished with exit code: \(exitCode, privacy: .public)")
			helper.exit(code: exitCode)
			if exitCode == Int(EXIT_SUCCESS) {
				DispatchQueue.main.async {
					self.finishProcessing()
				}
			}
		}

		helperProgress.resignCurrent()
		progress = helperProgress

		progressObserverToken = helperProgress.observe(\.completedUnitCount) { progress, _ in
			print(progress)
			print(progress.userInfo)
			print(progress.completedUnitCount)
			if let url = progress.fileURL, let size = progress.userInfo[ProgressUserInfoKey.sizeDifference] as? Int {
				self.processProgress(file: url, size: size, appName: progress.userInfo[ProgressUserInfoKey.appName] as? String)
			}
		}

		if progressViewController == nil {
			let storyboard = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil)
			progressViewController = storyboard.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier("ProgressViewController")) as? ProgressViewController
		}
		progressViewController?.delegate = self
		if progressViewController!.presentingViewController == nil {
			presentAsSheet(progressViewController!)
		}

		let content = UNMutableNotificationContent()
		content.title = NSLocalizedString("Monolingual started", comment: "")
		content.body = NSLocalizedString("Started removing files", comment: "")

		let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: Date())
		let trigger = UNCalendarNotificationTrigger(dateMatching: now, repeats: false)
		let request = UNNotificationRequest(identifier: UUID().uuidString,
		                                    content: content,
		                                    trigger: trigger)

		UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
	}

	private func checkAndRunHelper(arguments: HelperRequest) {
		let xpcService = xpcServiceConnection.remoteObjectProxyWithErrorHandler { error -> Void in
			self.logger.error("XPCService error: \(error.localizedDescription, privacy: .public)")
		} as? XPCServiceProtocol

		if let xpcService = xpcService {
			xpcService.connect { endpoint -> Void in
				if let endpoint = endpoint {
					var performInstallation = false
					let connection = NSXPCConnection(listenerEndpoint: endpoint)
					let interface = NSXPCInterface(with: HelperProtocol.self)
					interface.setInterface(NSXPCInterface(with: ProgressProtocol.self), for: #selector(HelperProtocol.process(request:progress:reply:)), argumentIndex: 1, ofReply: false)
					connection.remoteObjectInterface = interface
					connection.invalidationHandler = {
						self.logger.error("XPC connection to helper invalidated.")
						self.helperConnection = nil
						if performInstallation {
							self.installHelper { success in
								if success {
									self.checkAndRunHelper(arguments: arguments)
								}
							}
						}
					}
					connection.resume()
					self.helperConnection = connection

					if let connection = self.helperConnection {
						guard let helper = connection.remoteObjectProxyWithErrorHandler({ error in
							self.logger.error("Error connecting to helper: \(error.localizedDescription, privacy: .public)")
						}) as? HelperProtocol else {
							self.logger.error("Helper does not conform to HelperProtocol")
							return
						}

						helper.getVersion { installedVersion in
							xpcService.bundledHelperVersion { bundledVersion in
								if installedVersion == bundledVersion {
									// helper is current
									DispatchQueue.main.async {
										self.runHelper(helper, arguments: arguments)
									}
								} else {
									// helper is different version
									performInstallation = true
									// this triggers rdar://23143866 (duplicate of rdar://19601397)
									// helper.uninstall()
									helper.exit(code: Int(EXIT_SUCCESS))
									connection.invalidate()
									xpcService.disconnect()
								}
							}
						}
					}
				} else {
					self.logger.error("Failed to get XPC endpoint.")
					self.installHelper { success in
						if success {
							self.checkAndRunHelper(arguments: arguments)
						}
					}
				}
			}
		}
	}

	func progressViewControllerDidCancel(_: ProgressViewController) {
		progressDidEnd(completed: false)
	}

	private func progressDidEnd(completed: Bool) {
		guard let progress = progress else { return }

		processApplication = nil
		if let progressViewController = progressViewController {
			dismiss(progressViewController)
		}
		progressResetTimer?.invalidate()
		progressResetTimer = nil

		let byteCount = ByteCountFormatter.string(fromByteCount: max(progress.completedUnitCount, 0), countStyle: .file)
		progressObserverToken?.invalidate()
		self.progress = nil

		if !completed {
			// cancel the current progress which tells the helper to stop
			progress.cancel()
			logger.debug("Closing progress connection")

			if let helper = helperConnection?.remoteObjectProxy as? HelperProtocol {
				helper.exit(code: Int(EXIT_FAILURE))
			}

			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("You cancelled the removal. Some files were erased, some were not.", comment: "")
			alert.informativeText = String(format: NSLocalizedString("Space saved: %@.", comment: ""), byteCount)
			alert.beginSheetModal(for: view.window!, completionHandler: nil)
		} else {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("Files removed.", comment: "")
			alert.informativeText = String(format: NSLocalizedString("Space saved: %@.", comment: ""), byteCount)
			alert.beginSheetModal(for: view.window!, completionHandler: nil)

			let content = UNMutableNotificationContent()
			content.title = NSLocalizedString("Monolingual finished", comment: "")
			content.body = NSLocalizedString("Finished removing files", comment: "")

			let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: Date())
			let trigger = UNCalendarNotificationTrigger(dateMatching: now, repeats: false)
			let request = UNNotificationRequest(identifier: UUID().uuidString,
			                                    content: content,
			                                    trigger: trigger)

			UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
		}

		if let connection = helperConnection {
			logger.info("Closing connection to helper")
			connection.invalidate()
			helperConnection = nil
		}

		log.close()

		ProcessInfo.processInfo.enableSuddenTermination()
	}

	private func checkAndRemove() {
		if checkRoots(), checkLanguages() {
			doRemoveLanguages()
		}
	}

	private func checkRoots() -> Bool {
		var languageEnabled = false
		let roots = roots
		for root in roots where root.languages {
			languageEnabled = true
			break
		}

		if !languageEnabled {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("Monolingual is stopping without making any changes.", comment: "")
			alert.informativeText = NSLocalizedString("Your OS has not been modified.", comment: "")
			alert.beginSheetModal(for: view.window!, completionHandler: nil)
		}

		return languageEnabled
	}

	private func checkLanguages() -> Bool {
		var englishChecked = false
		for language in languages where language.enabled && language.folders[0] == "en.lproj" {
			englishChecked = true
			break
		}

		if englishChecked {
			// Display a warning
			let alert = NSAlert()
			alert.alertStyle = .critical
			alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
			alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
			alert.messageText = NSLocalizedString("You are about to delete the English language files.", comment: "")
			alert.informativeText = NSLocalizedString("Are you sure you want to do that?", comment: "")

			alert.beginSheetModal(for: view.window!) { response in
				if response == NSApplication.ModalResponse.alertSecondButtonReturn {
					self.doRemoveLanguages()
				}
			}
		}

		return !englishChecked
	}

	private func doRemoveLanguages() {
		mode = .languages

		log.open()
		let version = (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? "vUNKNOWN"
		log.message("Monolingual \(version) started\n")
		log.message("Removing languages:")

		let roots = roots

		let includes = roots.filter(\.languages).map(\.path)
		let excludes = roots.filter { !$0.languages }.map(\.path) + sipProtectedLocations
		let bl = blocklist!.filter(\.languages).map(\.bundle)

		for item in bl {
			logger.info("Blocklisting \(item, privacy: .public)")
		}
		for include in includes {
			logger.info("Adding root \(include, privacy: .public)")
		}
		for exclude in excludes {
			logger.info("Excluding root \(exclude, privacy: .public)")
		}

		var rCount = 0
		var folders = Set<String>()
		for language in languages where language.enabled {
			for path in language.folders {
				folders.insert(path)
				log.message(" \(path)", timestamp: false)
				rCount += 1
			}
		}
		if UserDefaults.standard.bool(forKey: "NIB") {
			folders.insert("designable.nib")
		}

		log.message("\n", timestamp: false)
		if UserDefaults.standard.bool(forKey: "Trash") {
			log.message("Trashed files:\n")
		} else {
			log.message("Deleted files:\n")
		}

		if rCount == languages.count {
			let alert = NSAlert()
			alert.alertStyle = .informational
			alert.messageText = NSLocalizedString("Removing all languages will make macOS inoperable.", comment: "")
			alert.informativeText = NSLocalizedString("Please keep at least one language and try again.", comment: "")
			alert.beginSheetModal(for: view.window!, completionHandler: nil)
			log.close()
		} else if rCount > 0 {
			// start things off if we have something to remove!

			let request = HelperRequest()
			request.trash = UserDefaults.standard.bool(forKey: "Trash")
			request.uid = getuid()
			request.bundleBlocklist = Set<String>(bl)
			request.includes = includes
			request.excludes = excludes
			request.directories = folders

			checkAndRunHelper(arguments: request)
		} else {
			log.close()
		}
	}

	override func viewDidLoad() {
		let currentLocale = Locale.current

		// never check the user's preferred languages, English and the user's locale by default
		let userLanguages = Set<String>(Locale.preferredLanguages.flatMap { language -> [String] in
			let components = language.components(separatedBy: "-")
			if components.count == 1 {
				return [components[0]]
			} else {
				return [components[0], components.joined(separator: "_")]
			}
		} + ["en", currentLocale.identifier, currentLocale.languageCode ?? ""])

		let knownLocales: [String] = ["ach", "an", "ast", "ay", "bi", "co", "fur", "gd", "gn", "ia", "jv", "ku", "la", "mi", "md", "no", "oc", "qu", "sa", "sd", "se", "su", "tet", "tk_Cyrl", "tl", "tlh", "tt", "wa", "yi", "zh_CN", "zh_TW"]
		// add some known locales not contained in availableLocaleIdentifiers
		let availableLocalizations = Set<String>(Locale.availableIdentifiers + knownLocales)

		let systemLocale = Locale(identifier: "en_US_POSIX")
		languages = [String](availableLocalizations).map { localeIdentifier -> LanguageSetting in
			var folders = ["\(localeIdentifier).lproj"]
			let locale = Locale(identifier: localeIdentifier)
			if let language = locale.languageCode, let region = locale.regionCode {
				if let variantCode = locale.variantCode {
					// e.g. en_US_POSIX
					folders.append("\(language)-\(region)_\(variantCode).lproj")
					folders.append("\(language)_\(region)_\(variantCode).lproj")
				} else if let script = locale.scriptCode {
					// e.g. zh_Hans_SG
					folders.append("\(language)-\(script)-\(region).lproj")
					folders.append("\(language)_\(script)_\(region).lproj")
				} else {
					folders.append("\(language)-\(region).lproj")
					folders.append("\(language)_\(region).lproj")
				}
			} else if let language = locale.languageCode, let script = locale.scriptCode {
				// e.g. zh_Hans
				folders.append("\(language)-\(script).lproj")
				folders.append("\(language)_\(script).lproj")
			} else if let displayName = systemLocale.localizedString(forIdentifier: localeIdentifier) {
				folders.append("\(displayName).lproj")
			}
			let displayName = currentLocale.localizedString(forIdentifier: localeIdentifier) ?? NSLocalizedString("locale_\(localeIdentifier)", comment: "")
			return LanguageSetting(id: 0, enabled: !userLanguages.contains(localeIdentifier), folders: folders, displayName: displayName)
		}.sorted { $0.displayName < $1.displayName }

		// swiftlint:disable comma
		let archs = [
			ArchitectureInfo(name: "arm", displayName: "ARM", cpuType: CPU_TYPE_ARM, cpuSubtype: CPU_SUBTYPE_ARM_ALL),
			ArchitectureInfo(name: "arm64", displayName: "ARM64", cpuType: CPU_TYPE_ARM64, cpuSubtype: CPU_SUBTYPE_ARM64_ALL),
			ArchitectureInfo(name: "arm64v8", displayName: "ARM64v8", cpuType: CPU_TYPE_ARM64, cpuSubtype: CPU_SUBTYPE_ARM64_V8),
			ArchitectureInfo(name: "arm64e", displayName: "ARM64E", cpuType: CPU_TYPE_ARM64, cpuSubtype: CPU_SUBTYPE_ARM64E),
			ArchitectureInfo(name: "ppc", displayName: "PowerPC", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_ALL),
			ArchitectureInfo(name: "ppc750", displayName: "PowerPC G3", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_750),
			ArchitectureInfo(name: "ppc7400", displayName: "PowerPC G4", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_7400),
			ArchitectureInfo(name: "ppc7450", displayName: "PowerPC G4+", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_7450),
			ArchitectureInfo(name: "ppc970", displayName: "PowerPC G5", cpuType: CPU_TYPE_POWERPC, cpuSubtype: CPU_SUBTYPE_POWERPC_970),
			ArchitectureInfo(name: "ppc64", displayName: "PowerPC 64-bit", cpuType: CPU_TYPE_POWERPC64, cpuSubtype: CPU_SUBTYPE_POWERPC_ALL),
			ArchitectureInfo(name: "ppc970-64", displayName: "PowerPC G5 64-bit", cpuType: CPU_TYPE_POWERPC64, cpuSubtype: CPU_SUBTYPE_POWERPC_970),
			ArchitectureInfo(name: "x86", displayName: "Intel 32-bit", cpuType: CPU_TYPE_X86, cpuSubtype: CPU_SUBTYPE_X86_ALL),
			ArchitectureInfo(name: "x86_64", displayName: "Intel 64-bit", cpuType: CPU_TYPE_X86_64, cpuSubtype: CPU_SUBTYPE_X86_64_ALL),
			ArchitectureInfo(name: "x86_64h", displayName: "Intel 64-bit (Haswell)", cpuType: CPU_TYPE_X86_64, cpuSubtype: CPU_SUBTYPE_X86_64_H),
		]
		// swiftlint:enable comma

		var infoCount = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<host_info_t>.size) // HOST_BASIC_INFO_COUNT
		var hostInfo = host_basic_info_data_t(max_cpus: 0, avail_cpus: 0, memory_size: 0, cpu_type: 0, cpu_subtype: 0, cpu_threadtype: 0, physical_cpu: 0, physical_cpu_max: 0, logical_cpu: 0, logical_cpu_max: 0, max_mem: 0)
		let myMachHostSelf = mach_host_self()
		let ret = withUnsafeMutablePointer(to: &hostInfo) { (pointer: UnsafeMutablePointer<host_basic_info_data_t>) in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { pointer in
				host_info(myMachHostSelf, HOST_BASIC_INFO, pointer, &infoCount)
			}
		}
		mach_port_deallocate(mach_task_self(), myMachHostSelf)

		if hostInfo.cpu_type == CPU_TYPE_X86 {
			// fix host_info
			var x8664: Int = 0
			var x8664Size = Int(MemoryLayout<Int>.size)
			let ret = sysctlbyname("hw.optional.x86_64", &x8664, &x8664Size, nil, 0)
			if ret == 0 {
				if x8664 != 0 {
					hostInfo = host_basic_info_data_t(
						max_cpus: hostInfo.max_cpus,
						avail_cpus: hostInfo.avail_cpus,
						memory_size: hostInfo.memory_size,
						cpu_type: CPU_TYPE_X86_64,
						cpu_subtype: (hostInfo.cpu_subtype == CPU_SUBTYPE_X86_64_H) ? CPU_SUBTYPE_X86_64_H : CPU_SUBTYPE_X86_64_ALL,
						cpu_threadtype: hostInfo.cpu_threadtype,
						physical_cpu: hostInfo.physical_cpu,
						physical_cpu_max: hostInfo.physical_cpu_max,
						logical_cpu: hostInfo.logical_cpu,
						logical_cpu_max: hostInfo.logical_cpu_max,
						max_mem: hostInfo.max_mem
					)
				}
			}
		}

		currentArchitecture.stringValue = NSLocalizedString("unknown", comment: "")

		architectures = archs.map { arch in
			let enabled = ret == KERN_SUCCESS && hostInfo.cpu_type != arch.cpuType
			let architecture = ArchitectureSetting(id: 0, enabled: enabled, name: arch.name, displayName: arch.displayName)
			if hostInfo.cpu_type == arch.cpuType, hostInfo.cpu_subtype == arch.cpuSubtype {
				self.currentArchitecture.stringValue = String(format: NSLocalizedString("Current architecture: %@", comment: ""), arch.displayName)
			}
			return architecture
		}

		let decoder = PropertyListDecoder()

		// load blocklist from asset catalog
		if let blocklist = NSDataAsset(name: "blocklist") {
			self.blocklist = try? decoder.decode([BlocklistEntry].self, from: blocklist.data)
		}
		// load remote blocklist asynchronously
		DispatchQueue.main.async {
			if let blocklistURL = URL(string: "https://ingmarstein.github.io/Monolingual/blocklist.plist"), let data = try? Data(contentsOf: blocklistURL) {
				self.blocklist = try? decoder.decode([BlocklistEntry].self, from: data)
			}
		}
		/*
		 self.processApplicationObserver = NotificationCenter.default.addObserver(forName: processApplicationNotification, object: nil, queue: nil) { [weak self] notification in
		 if let dictionary = notification.userInfo {
		 self?.processApplication = Root(dictionary: dictionary)
		 }
		 }
		 */
	}

	deinit {
		if let observer = self.processApplicationObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		xpcServiceConnection.invalidate()
	}
}
