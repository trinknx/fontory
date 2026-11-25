import FontoryCore
import SwiftUI

/// Above the browser in the Google Fonts view: Google's category and the Vietnamese subset flag, bound to
/// `LibraryFilters.googleCategory` / `googleVietnamese` (Popular is in the sort menu). Cleared when the view is left.
struct GoogleFilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Picker("Category", selection: $model.filters.googleCategory) {
                Text("All").tag(String?.none)
                ForEach(AppModel.googleCategories, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Vietnamese", isOn: $model.filters.googleVietnamese)
                .toggleStyle(.checkbox)
                .help("Families whose Google Fonts subsets include Vietnamese")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
