import SwiftUI

// MARK: - Graph Data

struct GraphNode: Identifiable {
    let id: UUID
    let person: Person
    var position: CGPoint
}

struct GraphEdge: Identifiable {
    var id: String { "\(fromID)-\(toID)" }
    let fromID: UUID   // introducer (parent)
    let toID: UUID     // person (child)
}

// MARK: - Graph View

struct PersonGraphView: View {
    let people: [Person]

    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var selectedPersonID: UUID?
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @State private var navigateToPerson: Person?
    @State private var graphSize: CGSize = .zero

    private let nodeRadius: CGFloat = 26

    private var selectedNode: GraphNode? {
        nodes.first { $0.id == selectedPersonID }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.groupedBackground.ignoresSafeArea()

                if people.isEmpty {
                    emptyState
                } else if nodes.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Строю граф...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    canvasLayer
                }

                legend
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)

                controlsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
            }
            .onAppear {
                resetViewport()
                DispatchQueue.main.async {
                    graphSize = geo.size
                    buildGraph(in: geo.size)
                }
            }
            .onChange(of: geo.size) { _, newSize in
                graphSize = newSize
                buildGraph(in: newSize)
            }
            .onChange(of: people.map(\.id)) { _, _ in
                buildGraph(in: graphSize)
            }
            // NOTE: avoid traversing introducer links here; stale relations may exist
            // in local stores from older schema versions and can crash rendering.
        }
        .navigationDestination(item: $navigateToPerson) { person in
            PersonDetailView(person: person)
        }
    }

    // MARK: - Canvas

    private var canvasLayer: some View {
        ZStack {
            // Edges (non-interactive, drawn below nodes)
            ForEach(edges) { edge in
                edgeLine(edge)
                    .allowsHitTesting(false)
            }

            // Nodes
            ForEach(nodes) { node in
                nodeView(node: node)
            }

            // Tooltip layer — separate from nodes, positioned correctly
            if let selected = selectedNode {
                tooltipCard(for: selected.person)
                    .position(
                        x: selected.position.x,
                        y: selected.position.y - nodeRadius * 2 - 75
                    )
                    .zIndex(100)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .animation(.spring(duration: 0.25), value: selectedPersonID)
            }
        }
        // Apply canvas transform BEFORE gesture so gestures work in canvas space
        .scaleEffect(scale * pinchScale)
        .offset(
            x: offset.width + dragOffset.width,
            y: offset.height + dragOffset.height
        )
        .gesture(
            SimultaneousGesture(
                MagnifyGesture()
                    .updating($pinchScale) { value, state, _ in
                        state = value.magnification
                    }
                    .onEnded { value in
                        scale = max(0.3, min(3.0, scale * value.magnification))
                    },
                DragGesture(minimumDistance: 12)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        offset.width  += value.translation.width
                        offset.height += value.translation.height
                    }
            )
        )
        .onTapGesture {
            // Tap on empty canvas area → deselect
            withAnimation(.spring(duration: 0.2)) {
                selectedPersonID = nil
            }
        }
    }

    // MARK: - Edge

    @ViewBuilder
    private func edgeLine(_ edge: GraphEdge) -> some View {
        if let parent = nodes.first(where: { $0.id == edge.fromID }),
           let child  = nodes.first(where: { $0.id == edge.toID }) {
            let dx = child.position.x - parent.position.x
            let sign: CGFloat = dx >= 0 ? 1 : -1
            let bend = max(50, abs(dx) * 0.45)

            Path { path in
                path.move(to: parent.position)
                path.addCurve(
                    to: child.position,
                    control1: CGPoint(x: parent.position.x + bend * sign, y: parent.position.y),
                    control2: CGPoint(x: child.position.x - bend * sign, y: child.position.y)
                )
            }
            .stroke(
                Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
    }

    // MARK: - Node

    @ViewBuilder
    private func nodeView(node: GraphNode) -> some View {
        let isSelected = selectedPersonID == node.id
        let person = node.person
        let shortName = {
            let base = person.name.components(separatedBy: " ").first ?? person.name
            return base.count > 14 ? String(base.prefix(14)) + "…" : base
        }()

        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Color(hex: person.colorHex).gradient)
                    .frame(width: nodeRadius * 2, height: nodeRadius * 2)
                    .overlay(
                        Circle().strokeBorder(
                            isSelected ? Color.white : Color.clear,
                            lineWidth: 3
                        )
                    )
                    .shadow(
                        color: Color(hex: person.colorHex).opacity(isSelected ? 0.7 : 0.3),
                        radius: isSelected ? 14 : 5
                    )
                    .scaleEffect(isSelected ? 1.18 : 1.0)

                Text(person.initials)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Text(shortName)
                .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 110)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    isSelected ? Color(hex: person.colorHex).opacity(0.15) : Color.clear,
                    in: Capsule()
                )
        }
        .animation(.spring(duration: 0.25), value: isSelected)
        .position(node.position)
        // Use onTapGesture — no conflict with parent DragGesture
        .onTapGesture {
            withAnimation(.spring(duration: 0.3)) {
                if selectedPersonID == node.id {
                    // Second tap → open profile
                    navigateToPerson = person
                } else {
                    selectedPersonID = node.id
                }
            }
        }
        // High priority so drag on node body doesn't start canvas pan
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in }
        )
    }

    // MARK: - Tooltip

    private func tooltipCard(for person: Person) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(person.name)
                .font(.subheadline).fontWeight(.semibold)

            if !person.displayRole.isEmpty {
                Text(person.displayRole)
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !person.categoryTags.isEmpty {
                Text(person.categoryTags.prefix(3).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Color.accentColor)
            }

            if let last = person.lastInteraction {
                Label(last.date.relativeLabel, systemImage: last.type.icon)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            Text("Нажми ещё раз — открыть профиль")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("Нет контактов")
                .font(.title3).fontWeight(.semibold)
            Text("Добавь людей, чтобы построить карту контактов")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(.blue.gradient).frame(width: 12, height: 12)
                Text("Контакт").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 16, height: 1.5)
                Text("Связь").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Нажми на узел — детали\nЕщё раз — открыть профиль")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Controls

    private var controlsPanel: some View {
        HStack(spacing: 8) {
            controlButton(icon: "plus.magnifyingglass") {
                withAnimation { scale = min(3.0, scale + 0.25) }
            }
            controlButton(icon: "minus.magnifyingglass") {
                withAnimation { scale = max(0.3, scale - 0.25) }
            }
            controlButton(icon: "arrow.up.left.and.arrow.down.right") {
                withAnimation(.spring(duration: 0.4)) {
                    scale = 1.0
                    offset = .zero
                }
            }
        }
    }

    private func controlButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Graph Layout (mindmap-style)

    private func buildGraph(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let horizontalStep = max(170, min(260, size.width * 0.22))
        let verticalStep: CGFloat = 88

        // Temporary safe mode: relation edges are disabled while stale introducer
        // references are being phased out by schema updates.
        let childrenByIntroducer: [UUID: [Person]] = [:]

        // With edges disabled, every contact acts as a root node.
        var roots = people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if roots.isEmpty, let first = people.sorted(by: { $0.name < $1.name }).first {
            roots = [first]
        }

        // Alternate sides for root branches: right, left, right, ...
        var sideByRoot: [UUID: Int] = [:] // -1 left, +1 right
        for (idx, root) in roots.enumerated() {
            sideByRoot[root.id] = (idx % 2 == 0) ? 1 : -1
        }

        // Vertical budget per side (based on subtree leaf count)
        var leafCountBySide: [Int: Int] = [-1: 0, 1: 0]
        for root in roots {
            let side = sideByRoot[root.id] ?? 1
            leafCountBySide[side, default: 0] += subtreeLeafCount(
                personID: root.id,
                childrenByIntroducer: childrenByIntroducer
            )
        }

        var nextY: [Int: CGFloat] = [:]
        for side in [-1, 1] {
            let leaves = max(1, leafCountBySide[side, default: 1])
            nextY[side] = center.y - (CGFloat(leaves - 1) * verticalStep / 2)
        }

        var positions: [UUID: CGPoint] = [:]

        for root in roots {
            let side = sideByRoot[root.id] ?? 1
            let children = (childrenByIntroducer[root.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            if children.isEmpty {
                let y = nextY[side] ?? center.y
                nextY[side] = y + verticalStep
                positions[root.id] = CGPoint(x: center.x, y: y)
                continue
            }

            var childYs: [CGFloat] = []
            for child in children {
                let y = layoutSubtree(
                    person: child,
                    depth: 1,
                    side: side,
                    center: center,
                    horizontalStep: horizontalStep,
                    verticalStep: verticalStep,
                    nextY: &nextY,
                    positions: &positions,
                    childrenByIntroducer: childrenByIntroducer
                )
                childYs.append(y)
            }
            positions[root.id] = CGPoint(x: center.x, y: (childYs.min()! + childYs.max()!) / 2)
        }

        // Safety fallback for malformed/cyclic branches
        for person in people where positions[person.id] == nil {
            let y = nextY[1] ?? center.y
            nextY[1] = y + verticalStep
            positions[person.id] = CGPoint(x: center.x + horizontalStep, y: y)
        }

        let newNodes: [GraphNode] = people.map { person in
            GraphNode(
                id: person.id,
                person: person,
                position: positions[person.id] ?? center
            )
        }

        let newEdges: [GraphEdge] = []

        withAnimation(.spring(duration: 0.45)) {
            nodes = newNodes
            edges = newEdges
        }
    }

    private func subtreeLeafCount(
        personID: UUID,
        childrenByIntroducer: [UUID: [Person]]
    ) -> Int {
        let children = childrenByIntroducer[personID] ?? []
        if children.isEmpty { return 1 }
        return children.reduce(0) { partial, child in
            partial + subtreeLeafCount(personID: child.id, childrenByIntroducer: childrenByIntroducer)
        }
    }

    private func layoutSubtree(
        person: Person,
        depth: Int,
        side: Int,
        center: CGPoint,
        horizontalStep: CGFloat,
        verticalStep: CGFloat,
        nextY: inout [Int: CGFloat],
        positions: inout [UUID: CGPoint],
        childrenByIntroducer: [UUID: [Person]]
    ) -> CGFloat {
        let children = (childrenByIntroducer[person.id] ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let x = center.x + CGFloat(side) * horizontalStep * CGFloat(depth)
        if children.isEmpty {
            let y = nextY[side] ?? center.y
            nextY[side] = y + verticalStep
            positions[person.id] = CGPoint(x: x, y: y)
            return y
        }

        var ys: [CGFloat] = []
        for child in children {
            ys.append(
                layoutSubtree(
                    person: child,
                    depth: depth + 1,
                    side: side,
                    center: center,
                    horizontalStep: horizontalStep,
                    verticalStep: verticalStep,
                    nextY: &nextY,
                    positions: &positions,
                    childrenByIntroducer: childrenByIntroducer
                )
            )
        }

        let y = (ys.min()! + ys.max()!) / 2
        positions[person.id] = CGPoint(x: x, y: y)
        return y
    }

    private func resetViewport() {
        scale = 1.0
        offset = .zero
        selectedPersonID = nil
    }
}
