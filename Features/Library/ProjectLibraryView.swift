import AppKit
import SwiftUI

struct ProjectLibraryView: View {
  @Environment(ProjectStore.self) private var projectStore
  @Environment(AppLanguageStore.self) private var languageStore
  @Environment(WorkflowNavigator.self) private var workflowNavigator

  @State private var deletePendingIDs: Set<UUID> = []
  @State private var showingClearCacheConfirmation = false
  @State private var searchText = ""
  @State private var selectedProjectIDs = Set<UUID>()

  private var filteredProjects: [ProjectStore.ProjectSummary] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return projectStore.projects }
    return projectStore.projects.filter { summary in
      displayTitle(for: summary).localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      storageToolbar
      Divider()
      searchField
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      if projectStore.projects.isEmpty {
        emptyState
      } else if filteredProjects.isEmpty {
        noSearchResultsState
      } else {
        projectTable
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .confirmationDialog(
      deleteConfirmationTitle,
      isPresented: Binding(get: { !deletePendingIDs.isEmpty }, set: { if !$0 { deletePendingIDs = [] } }),
      titleVisibility: .visible
    ) {
      Button(L("削除"), role: .destructive) {
        let ids = deletePendingIDs
        projectStore.deleteProjects(ids: ids)
        selectedProjectIDs.subtract(ids)
        deletePendingIDs = []
      }
      Button(L("キャンセル"), role: .cancel) {
        deletePendingIDs = []
      }
    } message: {
      Text(deleteConfirmationMessage)
    }
    .confirmationDialog(
      L("一時キャッシュを削除しますか？"),
      isPresented: $showingClearCacheConfirmation,
      titleVisibility: .visible
    ) {
      Button(L("削除"), role: .destructive) {
        projectStore.clearTemporaryRecordingCache()
      }
      Button(L("キャンセル"), role: .cancel) {}
    } message: {
      Text(
        languageStore.localizedFormat(
          "録画処理の一時ファイル（%@）を削除します。保存済みプロジェクトには影響しません。",
          ProjectStorageCatalog.formattedByteCount(projectStore.storageOverview.temporaryCacheBytes)
        )
      )
    }
    .onChange(of: projectStore.projects) { _, projects in
      let validIDs = Set(projects.map(\.id))
      selectedProjectIDs = selectedProjectIDs.intersection(validIDs)
    }
  }

  private var deleteConfirmationTitle: String {
    deletePendingIDs.count == 1 ? L("このプロジェクトを削除しますか？") : L("選択したプロジェクトを削除しますか？")
  }

  private var deleteConfirmationMessage: String {
    if deletePendingIDs.count == 1,
       let summary = projectStore.projects.first(where: { deletePendingIDs.contains($0.id) }) {
      return displayTitle(for: summary)
    }
    return languageStore.localizedFormat("選択した %d 件のプロジェクトを削除します。", deletePendingIDs.count)
  }

  private var storageToolbar: some View {
    let overview = projectStore.storageOverview
    return HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L("ストレージ"))
          .font(.title3.weight(.semibold))
        Text(
          languageStore.localizedFormat(
            "%d 件のプロジェクト · %@",
            overview.projectCount,
            ProjectStorageCatalog.formattedByteCount(overview.projectsBytes)
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      if !selectedProjectIDs.isEmpty {
        Text(languageStore.localizedFormat("%d 件を選択中", selectedProjectIDs.count))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      if overview.temporaryCacheBytes > 0 {
        Text(
          languageStore.localizedFormat(
            "一時キャッシュ %@",
            ProjectStorageCatalog.formattedByteCount(overview.temporaryCacheBytes)
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Button(L("一覧を更新")) {
        projectStore.refreshProjects()
      }

      Menu {
        Button(L("プロジェクトフォルダを開く")) {
          revealProjectsFolderInFinder()
        }
        Button(L("一時キャッシュを削除…")) {
          showingClearCacheConfirmation = true
        }
        .disabled(overview.temporaryCacheBytes <= 0)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .help(L("ストレージの管理"))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(L("録画を検索"), text: $searchText)
        .textFieldStyle(.plain)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(L("保存済みの録画はまだありません"), systemImage: "folder")
    } description: {
      Text(L("録画を停止すると、ここにプロジェクトとして表示されます。"))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var noSearchResultsState: some View {
    ContentUnavailableView {
      Label(L("一致する録画がありません"), systemImage: "magnifyingglass")
    } description: {
      Text(L("別のキーワードで検索してください。"))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var projectTable: some View {
    Table(filteredProjects, selection: $selectedProjectIDs) {
      TableColumn(L("タイトル")) { summary in
        Text(displayTitle(for: summary))
          .lineLimit(1)
      }
      .width(min: 220, ideal: 360)

      TableColumn(L("日時")) { summary in
        Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
          .foregroundStyle(.secondary)
      }
      .width(ideal: 160)

      TableColumn(L("サイズ")) { summary in
        Text(ProjectStorageCatalog.formattedByteCount(summary.storageBytes))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .width(ideal: 88)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .contextMenu(forSelectionType: UUID.self) { selection in
      if selection.count == 1,
         let id = selection.first,
         let summary = projectStore.projects.first(where: { $0.id == id }) {
        Button(L("開く")) { openProject(summary) }
        Button(L("Finderで表示")) { projectStore.revealProjectsInFinder(ids: selection) }
        Divider()
        Button(L("削除"), role: .destructive) { requestDelete(ids: selection) }
      } else if selection.count > 1 {
        Button(L("Finderで表示")) { projectStore.revealProjectsInFinder(ids: selection) }
        Button(L("削除"), role: .destructive) { requestDelete(ids: selection) }
      }
    } primaryAction: { selection in
      guard selection.count == 1,
            let id = selection.first,
            let summary = projectStore.projects.first(where: { $0.id == id })
      else { return }
      openProject(summary)
    }
    .toolbar {
      ToolbarItemGroup {
        if !selectedProjectIDs.isEmpty {
          Text(languageStore.localizedFormat("%d 件を選択中", selectedProjectIDs.count))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Button(L("開く")) { openSelectedProject() }
          .disabled(selectedProjectIDs.count != 1)
        Button(L("Finderで表示")) { revealSelectedProjectsInFinder() }
          .disabled(selectedProjectIDs.isEmpty)
        Button(L("削除"), role: .destructive) { requestDelete(ids: selectedProjectIDs) }
          .disabled(selectedProjectIDs.isEmpty)
      }
    }
  }

  private func L(_ key: String) -> String {
    languageStore.localized(key)
  }

  private func displayTitle(for summary: ProjectStore.ProjectSummary?) -> String {
    guard let summary else { return "" }
    return languageStore.localizedProjectDisplayTitle(
      storedTitle: summary.title,
      createdAt: summary.createdAt
    )
  }

  private func openProject(_ summary: ProjectStore.ProjectSummary) {
    projectStore.loadProject(id: summary.id)
    guard projectStore.current?.id == summary.id else { return }
    workflowNavigator.sidebarTab = .edit
  }

  private func openSelectedProject() {
    guard selectedProjectIDs.count == 1,
          let id = selectedProjectIDs.first,
          let summary = projectStore.projects.first(where: { $0.id == id })
    else { return }
    openProject(summary)
  }

  private func revealSelectedProjectsInFinder() {
    guard !selectedProjectIDs.isEmpty else { return }
    projectStore.revealProjectsInFinder(ids: selectedProjectIDs)
  }

  private func requestDelete(ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    deletePendingIDs = ids
  }

  private func revealProjectsFolderInFinder() {
    guard let url = try? ProjectStorageCatalog.projectsDirectoryURL() else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
