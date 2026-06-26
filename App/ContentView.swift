import SwiftUI

struct ContentView: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppAlertCenter.self) private var alertCenter
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(WorkflowNavigator.self) private var workflowNav
  @Environment(RecordingCoordinator.self) private var recordingCoordinator
  @Environment(\.scenePhase) private var scenePhase

  @State private var renameText: String = ""
  @State private var showingRecordingPermissionSetup = !Self.recordingPermissionIntroCompleted

  private static var recordingPermissionIntroCompleted: Bool {
    UserDefaults.standard.bool(forKey: AppIdentifiers.UserDefaultsKeys.recordingPermissionIntroCompleted)
  }

  private var hasCurrentProject: Bool {
    projectStore.current != nil
  }

  var body: some View {
    Group {
      if showingRecordingPermissionSetup {
        RecordingPermissionSetupView {
          completeRecordingPermissionIntro()
          showingRecordingPermissionSetup = false
          recordingCoordinator.setFloatingLauncherVisible(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          recordingCoordinator.setFloatingLauncherVisible(false)
        }
      } else if ScreenshotTour.isActive {
        screenshotTourWorkspace
      } else {
        NavigationSplitView {
          sidebarColumn
        } detail: {
          detailColumn
        }
        .navigationTitle("ArcShot")
      }
    }
    .sheet(isPresented: Binding(
      get: { workflowNav.showingReviewShortcutsHelp },
      set: { workflowNav.showingReviewShortcutsHelp = $0 }
    )) {
      ReviewShortcutsHelpSheet()
    }
    .task {
      projectStore.refreshProjects()
      refreshRecordingPermissionSetup()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      refreshRecordingPermissionSetup()
    }
    .onChange(of: projectStore.lastErrorMessage) { _, msg in
      guard let msg else { return }
      alertCenter.present(msg)
    }
    .onChange(of: projectStore.current?.id) { _, _ in
      guard let project = projectStore.current else {
        renameText = ""
        return
      }
      renameText = languageStore.localizedProjectDisplayTitle(
        storedTitle: project.title,
        createdAt: project.createdAt
      )
    }
    .onChange(of: workflowNav.sidebarTab) { _, tab in
      guard !hasCurrentProject, !tab.isAvailableWithoutOpenProject else { return }
      workflowNav.sidebarTab = WorkflowSidebarTab.defaultTabWithoutProject
    }
    .alert("ArcShot", isPresented: Binding(
      get: { alertCenter.current != nil },
      set: { newValue in if !newValue { alertCenter.current = nil } }
    ), presenting: alertCenter.current) { _ in
      Button("OK") {}
    } message: { alert in
      Text(alert.message)
    }
  }

  private func refreshRecordingPermissionSetup() {
    let needsSetup = !Self.recordingPermissionIntroCompleted
    showingRecordingPermissionSetup = needsSetup
    if needsSetup {
      recordingCoordinator.setFloatingLauncherVisible(false)
    }
  }

  private func completeRecordingPermissionIntro() {
    UserDefaults.standard.set(true, forKey: AppIdentifiers.UserDefaultsKeys.recordingPermissionIntroCompleted)
    UserDefaults.standard.synchronize()
  }

  private var sidebarColumn: some View {
    List {
      Section {
        ForEach(WorkflowSidebarTab.visibleTabs(screenshotTourActive: ScreenshotTour.isActive)) { tab in
          sidebarWorkflowButton(tab)
        }
      } header: {
        Text(languageStore.localized("ワークフロー"))
      }

      if let project = projectStore.current {
        Section {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              languageStore.localizedProjectDisplayTitle(
                storedTitle: project.title,
                createdAt: project.createdAt
              )
            )
            .lineLimit(2)
            Text(project.createdAt.formatted(date: .abbreviated, time: .shortened))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text(languageStore.localized("現在のプロジェクト"))
        }
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 200, ideal: 248)
  }

  private var screenshotTourWorkspace: some View {
    HStack(spacing: 0) {
      sidebarColumn
        .frame(width: 248)
        .background(Color(nsColor: .windowBackgroundColor))
      Divider()
      detailColumn
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var detailColumn: some View {
    VStack(alignment: .leading, spacing: AppUIMetrics.contentSpacing) {
      switch workflowNav.sidebarTab {
      case .capture:
        RecordView()
      case .library:
        ProjectLibraryView()
      case .edit:
        if hasCurrentProject {
          EditorView()
        } else {
          workflowLockedHint("編集")
        }
      case .export:
        if hasCurrentProject {
          ExportView()
        } else {
          workflowLockedHint("書き出し")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(workflowNav.sidebarTab == .library ? 0 : AppUIMetrics.rootPadding)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if let project = projectStore.current {
          HStack(spacing: AppUIMetrics.tightSpacing) {
            TextField(languageStore.localized("タイトル"), text: $renameText)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 280)
              .onAppear {
                renameText = languageStore.localizedProjectDisplayTitle(
                  storedTitle: project.title,
                  createdAt: project.createdAt
                )
              }
              .accessibilityLabel(languageStore.localized("プロジェクト名"))

            Button(languageStore.localized("名前を保存")) {
              projectStore.renameCurrentProject(title: renameText)
            }
            .accessibilityLabel(languageStore.localized("プロジェクト名を保存"))
            .accessibilityHint(languageStore.localized("編集したタイトルを書き込みます"))
          }
        }
      }
      ToolbarItemGroup(placement: .status) {
        if let project = projectStore.current {
          Text(project.mediaURL.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 220, alignment: .trailing)
            .accessibilityLabel(languageStore.localizedFormat("メディアファイル %@", project.mediaURL.lastPathComponent))
        }
      }
    }
  }

  private func workflowLockedHint(_ targetName: String) -> some View {
    let localizedTargetName = languageStore.localized(targetName)
    return VStack(alignment: .leading, spacing: AppUIMetrics.tightSpacing) {
      Text(languageStore.localizedFormat("%@を使うには録画が必要です", localizedTargetName))
        .font(.title3.weight(.semibold))
      Text(languageStore.localized("まず「キャプチャ」で録画を開始してください。"))
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(AppUIMetrics.rootPadding)
  }

  @ViewBuilder
  private func sidebarWorkflowButton(_ tab: WorkflowSidebarTab) -> some View {
    let selected = workflowNav.sidebarTab == tab
    let isLocked = !hasCurrentProject && !tab.isAvailableWithoutOpenProject
    Button {
      guard !isLocked else { return }
      workflowNav.sidebarTab = tab
    } label: {
      Label(languageStore.localized(tab.title), systemImage: tab.systemImage)
        .fontWeight(selected ? .semibold : .regular)
    }
    .buttonStyle(.plain)
    .disabled(isLocked)
    .opacity(isLocked ? 0.4 : 1)
    .foregroundStyle(selected ? Color.accentColor : Color.primary)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel(languageStore.localized(tab.title))
    .accessibilityHint(isLocked ? languageStore.localized("まずキャプチャを完了すると利用できます") : languageStore.localized("ワークフロー画面を切り替えます"))
  }
}
