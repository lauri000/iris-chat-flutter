class GroupOuterSubscriptionPlanResult {
  const GroupOuterSubscriptionPlanResult({
    required this.authors,
    required this.addedAuthors,
  });

  factory GroupOuterSubscriptionPlanResult.fromMap(Map<String, dynamic> map) {
    final authors = (map['authors'] as List?)
            ?.map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final addedAuthors = (map['addedAuthors'] as List?)
            ?.map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    return GroupOuterSubscriptionPlanResult(
      authors: authors,
      addedAuthors: addedAuthors,
    );
  }

  final List<String> authors;
  final List<String> addedAuthors;
}
