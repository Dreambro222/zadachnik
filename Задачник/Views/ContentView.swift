import SwiftUI

struct ContentView: View {
    @State private var showAlert = false

    var body: some View {
        VStack {
            Spacer()

            Button(action: {
                showAlert = true
            }) {
                Text("Hello Brother")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .blue.opacity(0.4), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .alert("Hello Brother!", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
