/// Sort options - matches MX Player Sort sheet (PDF page 2)
enum SortBy {
  title('Title'),
  date('Date'),
  playedTime('Played time'),
  status('Status'),
  length('Length'),
  size('Size'),
  resolution('Resolution'),
  path('Path'),
  frameRate('Frame rate'),
  type('Type');

  final String label;
  const SortBy(this.label);
}

enum SortDirection {
  oldestFirst('Oldest'),
  newestFirst('Newest');

  final String label;
  const SortDirection(this.label);
}

/// View mode for Local tab
enum ViewMode {
  allFolders('All folders'),
  files('Files'),
  folders('Folders');

  final String label;
  const ViewMode(this.label);
}

enum LayoutMode {
  list('List'),
  grid('Grid');

  final String label;
  const LayoutMode(this.label);
}
