#!/usr/bin/env python3
"""Generates PrettyShot.xcodeproj (project.pbxproj + shared scheme) from the source tree.

Object IDs are derived from file paths, so re-running after adding/removing files yields a
minimal diff. Run from anywhere:  python3 scripts/gen_xcodeproj.py

(Alternative: `xcodegen generate` with project.yml — both produce equivalent targets.)
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "PrettyShot"
TESTS = "PrettyShotTests"
BUNDLE_ID = "app.prettyshot.PrettyShot"
DEPLOYMENT = "14.0"
MARKETING_VERSION = "0.1.0"


def oid(*parts):
    return hashlib.md5("::".join(parts).encode()).hexdigest()[:24].upper()


def q(value):
    s = str(value)
    if s and all(c.isalnum() or c in "_./" for c in s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fmt(value, indent):
    pad = "\t" * indent
    if isinstance(value, dict):
        lines = ["{"]
        for k, v in value.items():
            lines.append(f"{pad}\t{q(k)} = {fmt(v, indent + 1)};")
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        lines = ["("]
        for v in value:
            lines.append(f"{pad}\t{fmt(v, indent + 1)},")
        lines.append(pad + ")")
        return "\n".join(lines)
    return q(value)


def scan(folder, exts):
    """Returns {relative_dir: [filenames]} for files under ROOT/folder with given extensions."""
    tree = {}
    base = os.path.join(ROOT, folder)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.endswith(".xcassets"))
        rel = os.path.relpath(dirpath, base)
        rel = "" if rel == "." else rel
        files = sorted(f for f in filenames if os.path.splitext(f)[1] in exts)
        assets = sorted(d for d in os.listdir(dirpath) if d.endswith(".xcassets"))
        if files or assets:
            tree[rel] = files + assets
    return tree


def main():
    objects = {}

    def add(key, obj):
        objects[key] = obj
        return key

    project_id = oid("project")
    main_group = oid("group", "main")
    products_group = oid("group", "Products")
    app_product = oid("product", APP)
    test_product = oid("product", TESTS)
    app_target = oid("target", APP)
    test_target = oid("target", TESTS)

    IOS = "PrettyShotIOS"
    SHARE = "PrettyShotShare"
    IOS_UI = "PrettyShotIOSUI"
    IOS_KIT = "PrettyShotIOSKit"
    IOS_TESTS = "PrettyShotIOSTests"
    IOS_BUNDLE = "app.prettyshot.ios"
    phases = {}
    for target in (APP, TESTS, IOS, SHARE, IOS_TESTS):
        for kind in ("sources", "frameworks", "resources"):
            phases[(target, kind)] = oid("phase", target, kind)
    build_files = {k: [] for k in phases}

    def build_group(folder, target, also_compile=()):
        tree = scan(folder, {".swift", ".plist", ".xcconfig", ".entitlements"})
        group_ids = {}

        def ensure_group(rel):
            if rel in group_ids:
                return group_ids[rel]
            gid = oid("group", folder, rel)
            group_ids[rel] = gid
            name = os.path.basename(rel) if rel else folder
            add(gid, {"isa": "PBXGroup", "children": [], "path": name, "sourceTree": "<group>"})
            if rel:
                parent = ensure_group(os.path.dirname(rel))
                objects[parent]["children"].append(gid)
            return gid

        ensure_group("")
        for rel in sorted(tree):
            gid = ensure_group(rel)
            for name in tree[rel]:
                path = os.path.join(folder, rel, name)
                fid = oid("file", path)
                ext = os.path.splitext(name)[1]
                ftype = {
                    ".swift": "sourcecode.swift",
                    ".plist": "text.plist.xml",
                    ".xcassets": "folder.assetcatalog",
                    ".xcconfig": "text.xcconfig",
                    ".entitlements": "text.plist.entitlements",
                }[ext]
                add(fid, {"isa": "PBXFileReference", "lastKnownFileType": ftype, "path": name, "sourceTree": "<group>"})
                objects[gid]["children"].append(fid)
                if ext == ".swift":
                    for compiled in (target,) + tuple(also_compile):
                        bid = oid("build", compiled, path)
                        add(bid, {"isa": "PBXBuildFile", "fileRef": fid})
                        build_files[(compiled, "sources")].append(bid)
                elif ext == ".xcassets":
                    bid = oid("build", target, path)
                    add(bid, {"isa": "PBXBuildFile", "fileRef": fid})
                    build_files[(target, "resources")].append(bid)
        # Folders first, then files, alphabetically — like Xcode.
        for gid in group_ids.values():
            children = objects[gid]["children"]
            children.sort(key=lambda c: (objects[c]["isa"] != "PBXGroup", objects[c]["path"].lower()))
        return group_ids[""]

    app_group = build_group(APP, APP)
    test_group = build_group(TESTS, TESTS)
    ios_group = build_group(IOS, IOS)
    share_group = build_group(SHARE, SHARE)
    kit_group = build_group(IOS_KIT, IOS, also_compile=(SHARE,))
    ui_group = build_group(IOS_UI, IOS, also_compile=(SHARE,))
    ios_test_group = build_group(IOS_TESTS, IOS_TESTS)

    ios_product = oid("product", IOS)
    share_product = oid("product", SHARE)
    ios_test_product = oid("product", IOS_TESTS)
    ios_target = oid("target", IOS)
    share_target = oid("target", SHARE)
    ios_test_target = oid("target", IOS_TESTS)

    add(app_product, {"isa": "PBXFileReference", "explicitFileType": "wrapper.application", "includeInIndex": 0,
                      "path": f"{APP}.app", "sourceTree": "BUILT_PRODUCTS_DIR"})
    add(test_product, {"isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle", "includeInIndex": 0,
                       "path": f"{TESTS}.xctest", "sourceTree": "BUILT_PRODUCTS_DIR"})
    add(ios_product, {"isa": "PBXFileReference", "explicitFileType": "wrapper.application", "includeInIndex": 0,
                      "path": f"{IOS}.app", "sourceTree": "BUILT_PRODUCTS_DIR"})
    add(share_product, {"isa": "PBXFileReference", "explicitFileType": "wrapper.app-extension", "includeInIndex": 0,
                        "path": f"{SHARE}.appex", "sourceTree": "BUILT_PRODUCTS_DIR"})
    add(ios_test_product, {"isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle", "includeInIndex": 0,
                           "path": f"{IOS_TESTS}.xctest", "sourceTree": "BUILT_PRODUCTS_DIR"})
    add(products_group, {"isa": "PBXGroup",
                         "children": [app_product, test_product, ios_product, share_product, ios_test_product],
                         "name": "Products", "sourceTree": "<group>"})

    doc_files = [f for f in ("README.md", "DEVIATIONS.md", "LICENSE") if os.path.exists(os.path.join(ROOT, f))]
    doc_refs = []
    for name in doc_files:
        fid = oid("file", name)
        ftype = "net.daringfireball.markdown" if name.endswith(".md") else "text"
        add(fid, {"isa": "PBXFileReference", "lastKnownFileType": ftype, "path": name, "sourceTree": "<group>"})
        doc_refs.append(fid)

    add(main_group, {"isa": "PBXGroup", "children": doc_refs + [
        app_group, test_group, kit_group, ui_group, ios_group, share_group, ios_test_group, products_group,
    ], "sourceTree": "<group>"})

    # Local Swift package (macOS + iOS). Static product, so no embed phase.
    package_ref = add(oid("package", "PrettyShotCore"), {
        "isa": "XCLocalSwiftPackageReference",
        "relativePath": "PrettyShotCore",
    })
    package_deps = {}
    for target in (APP, TESTS, IOS, SHARE, IOS_TESTS):
        dep = add(oid("pkgproduct", target, "PrettyShotCore"), {
            "isa": "XCSwiftPackageProductDependency",
            "package": package_ref,
            "productName": "PrettyShotCore",
        })
        bid = add(oid("pkgbuild", target, "PrettyShotCore"), {
            "isa": "PBXBuildFile",
            "productRef": dep,
        })
        build_files[(target, "frameworks")].append(bid)
        package_deps[target] = dep

    for (target, kind), pid in phases.items():
        isa = {"sources": "PBXSourcesBuildPhase", "frameworks": "PBXFrameworksBuildPhase",
               "resources": "PBXResourcesBuildPhase"}[kind]
        add(pid, {"isa": isa, "buildActionMask": 2147483647, "files": build_files[(target, kind)],
                  "runOnlyForDeploymentPostprocessing": 0})

    embed_file = add(oid("embed", IOS, SHARE), {
        "isa": "PBXBuildFile",
        "fileRef": share_product,
        "settings": {"ATTRIBUTES": ["RemoveHeadersOnCopy", "CodeSignOnCopy"]},
    })
    embed_phase = add(oid("phase", IOS, "embed"), {
        "isa": "PBXCopyFilesBuildPhase",
        "buildActionMask": 2147483647,
        "dstPath": "",
        "dstSubfolderSpec": 13,
        "files": [embed_file],
        "name": "Embed Foundation Extensions",
        "runOnlyForDeploymentPostprocessing": 0,
    })

    # --- Build configurations -------------------------------------------------
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT,
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "macosx",
    }
    project_debug = dict(common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    project_release = dict(common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
    })

    signing = {
        # Stable local identity (scripts/setup_local_signing.sh). Ad-hoc "-" changes the
        # cdhash every rebuild and macOS drops the Screen Recording grant.
        "CODE_SIGN_STYLE": "Manual",
        "CODE_SIGN_IDENTITY": "PrettyShot Local",
        "DEVELOPMENT_TEAM": "",
    }
    app_settings = dict(signing, **{
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP}/Resources/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
    })
    test_settings = dict(signing, **{
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}Tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_VERSION": "5.0",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{APP}.app/Contents/MacOS/{APP}",
    })

    def config_list(owner, settings_by_name, base=None):
        ids = []
        for name, settings in settings_by_name:
            cid = oid("config", owner, name)
            body = {"isa": "XCBuildConfiguration", "buildSettings": dict(sorted(settings.items())), "name": name}
            if base:
                body["baseConfigurationReference"] = base
            add(cid, body)
            ids.append(cid)
        lid = oid("configlist", owner)
        add(lid, {"isa": "XCConfigurationList", "buildConfigurations": ids,
                  "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"})
        return lid

    project_configs = config_list("project", [("Debug", project_debug), ("Release", project_release)])
    app_configs = config_list(APP, [("Debug", app_settings), ("Release", app_settings)])
    test_configs = config_list(TESTS, [("Debug", test_settings), ("Release", test_settings)])

    proxy = add(oid("proxy", TESTS), {"isa": "PBXContainerItemProxy", "containerPortal": project_id, "proxyType": 1,
                                      "remoteGlobalIDString": app_target, "remoteInfo": APP})
    dependency = add(oid("dependency", TESTS), {"isa": "PBXTargetDependency", "target": app_target,
                                                "targetProxy": proxy})

    add(app_target, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": app_configs,
        "buildPhases": [phases[(APP, "sources")], phases[(APP, "frameworks")], phases[(APP, "resources")]],
        "buildRules": [],
        "dependencies": [],
        "name": APP,
        "packageProductDependencies": [package_deps[APP]],
        "productName": APP,
        "productReference": app_product,
        "productType": "com.apple.product-type.application",
    })
    add(test_target, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": test_configs,
        "buildPhases": [phases[(TESTS, "sources")], phases[(TESTS, "frameworks")], phases[(TESTS, "resources")]],
        "buildRules": [],
        "dependencies": [dependency],
        "name": TESTS,
        "packageProductDependencies": [package_deps[TESTS]],
        "productName": TESTS,
        "productReference": test_product,
        "productType": "com.apple.product-type.bundle.unit-test",
    })

    ios_xcconfig = oid("file", os.path.join(IOS, "Handoff.xcconfig"))
    share_xcconfig = oid("file", os.path.join(SHARE, "Handoff.xcconfig"))
    ios_signing = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": MARKETING_VERSION,
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) $(PRETTYSHOT_HANDOFF_CONDITION)",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1",
    }
    ios_app_settings = dict(ios_signing, **{
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{IOS}/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": IOS_BUNDLE,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    })
    share_settings = dict(ios_signing, **{
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{SHARE}/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": f"{IOS_BUNDLE}.share",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    })
    ios_test_settings = dict(ios_signing, **{
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{IOS_BUNDLE}.tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{IOS}.app/{IOS}",
    })
    ios_configs = config_list(IOS, [("Debug", ios_app_settings), ("Release", ios_app_settings)], base=ios_xcconfig)
    share_configs = config_list(SHARE, [("Debug", share_settings), ("Release", share_settings)], base=share_xcconfig)
    ios_test_configs = config_list(IOS_TESTS, [("Debug", ios_test_settings), ("Release", ios_test_settings)], base=ios_xcconfig)

    share_proxy = add(oid("proxy", SHARE), {"isa": "PBXContainerItemProxy", "containerPortal": project_id, "proxyType": 1,
                                            "remoteGlobalIDString": share_target, "remoteInfo": SHARE})
    share_dependency = add(oid("dependency", IOS, SHARE), {"isa": "PBXTargetDependency", "target": share_target,
                                                          "targetProxy": share_proxy})
    ios_test_proxy = add(oid("proxy", IOS_TESTS), {"isa": "PBXContainerItemProxy", "containerPortal": project_id,
                                                   "proxyType": 1, "remoteGlobalIDString": ios_target, "remoteInfo": IOS})
    ios_test_dependency = add(oid("dependency", IOS_TESTS), {"isa": "PBXTargetDependency", "target": ios_target,
                                                            "targetProxy": ios_test_proxy})

    add(share_target, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": share_configs,
        "buildPhases": [phases[(SHARE, "sources")], phases[(SHARE, "frameworks")], phases[(SHARE, "resources")]],
        "buildRules": [],
        "dependencies": [],
        "name": SHARE,
        "packageProductDependencies": [package_deps[SHARE]],
        "productName": SHARE,
        "productReference": share_product,
        "productType": "com.apple.product-type.app-extension",
    })
    add(ios_target, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": ios_configs,
        "buildPhases": [phases[(IOS, "sources")], phases[(IOS, "frameworks")], phases[(IOS, "resources")], embed_phase],
        "buildRules": [],
        "dependencies": [share_dependency],
        "name": IOS,
        "packageProductDependencies": [package_deps[IOS]],
        "productName": IOS,
        "productReference": ios_product,
        "productType": "com.apple.product-type.application",
    })
    add(ios_test_target, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": ios_test_configs,
        "buildPhases": [phases[(IOS_TESTS, "sources")], phases[(IOS_TESTS, "frameworks")], phases[(IOS_TESTS, "resources")]],
        "buildRules": [],
        "dependencies": [ios_test_dependency],
        "name": IOS_TESTS,
        "packageProductDependencies": [package_deps[IOS_TESTS]],
        "productName": IOS_TESTS,
        "productReference": ios_test_product,
        "productType": "com.apple.product-type.bundle.unit-test",
    })

    add(project_id, {
        "isa": "PBXProject",
        "attributes": {
            "BuildIndependentTargetsInParallel": 1,
            "LastSwiftUpdateCheck": 1540,
            "LastUpgradeCheck": 1540,
            "TargetAttributes": {
                app_target: {"CreatedOnToolsVersion": "15.4"},
                test_target: {"CreatedOnToolsVersion": "15.4", "TestTargetID": app_target},
                ios_target: {"CreatedOnToolsVersion": "15.4"},
                share_target: {"CreatedOnToolsVersion": "15.4"},
                ios_test_target: {"CreatedOnToolsVersion": "15.4", "TestTargetID": ios_target},
            },
        },
        "buildConfigurationList": project_configs,
        "compatibilityVersion": "Xcode 14.0",
        "developmentRegion": "en",
        "hasScannedForEncodings": 0,
        "knownRegions": ["en", "Base", "zh-Hans"],
        "mainGroup": main_group,
        "packageReferences": [package_ref],
        "productRefGroup": products_group,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [app_target, test_target, ios_target, share_target, ios_test_target],
    })

    # --- Serialize --------------------------------------------------------------
    order = ["PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference", "PBXFrameworksBuildPhase", "PBXGroup",
             "PBXNativeTarget", "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase",
             "PBXTargetDependency", "XCBuildConfiguration", "XCConfigurationList",
             "XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency"]
    out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;",
           "\tobjects = {"]
    for isa in order:
        keys = sorted(k for k, v in objects.items() if v["isa"] == isa)
        if not keys:
            continue
        out.append("")
        out.append(f"/* Begin {isa} section */")
        for k in keys:
            obj = dict(objects[k])
            body = {"isa": obj.pop("isa")}
            body.update(dict(sorted(obj.items())))
            out.append(f"\t\t{k} = {fmt(body, 2)};")
        out.append(f"/* End {isa} section */")
    out += ["\t};", f"\trootObject = {project_id};", "}", ""]

    proj_dir = os.path.join(ROOT, f"{APP}.xcodeproj")
    os.makedirs(os.path.join(proj_dir, "xcshareddata", "xcschemes"), exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
        f.write("\n".join(out))

    ref = lambda target, name, product: (
        f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" '
        f'BuildableName = "{product}" BlueprintName = "{name}" ReferencedContainer = "container:{APP}.xcodeproj">'
        f'</BuildableReference>')
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1540" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref(app_target, APP, APP + ".app")}
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            {ref(test_target, TESTS, TESTS + ".xctest")}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES" shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference skipped = "NO" parallelizable = "NO">
            {ref(test_target, TESTS, TESTS + ".xctest")}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(app_target, APP, APP + ".app")}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(app_target, APP, APP + ".app")}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
'''
    with open(os.path.join(proj_dir, "xcshareddata", "xcschemes", f"{APP}.xcscheme"), "w") as f:
        f.write(scheme)

    ios_scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1540" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref(ios_target, IOS, IOS + ".app")}
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            {ref(share_target, SHARE, SHARE + ".appex")}
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            {ref(ios_test_target, IOS_TESTS, IOS_TESTS + ".xctest")}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO" parallelizable = "NO">
            {ref(ios_test_target, IOS_TESTS, IOS_TESTS + ".xctest")}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(ios_target, IOS, IOS + ".app")}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(ios_target, IOS, IOS + ".app")}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
'''
    with open(os.path.join(proj_dir, "xcshareddata", "xcschemes", f"{IOS}.xcscheme"), "w") as f:
        f.write(ios_scheme)

    n_app = len(build_files[(APP, "sources")])
    n_test = len(build_files[(TESTS, "sources")])
    n_ios = len(build_files[(IOS, "sources")])
    print(f"Generated {APP}.xcodeproj — {n_app} app sources, {n_test} test sources, {n_ios} iOS sources, {len(objects)} objects")


if __name__ == "__main__":
    main()
