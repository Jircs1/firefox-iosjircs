// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import SwiftUI
import Common
import Shared
import Storage

// MARK: - AddressCellView

/// A view representing a cell displaying address information.
struct AddressCellView: View {
    // MARK: - Properties

    @State private var textColor: Color = .clear
    @State private var customLightGray: Color = .clear
    @State private var iconPrimary: Color = .clear

    private(set) var address: Address
    @Environment(\.themeType)
    var themeVal
    private(set) var onTap: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 24) {
                    Image(StandardImageIdentifiers.Large.location)
                        .renderingMode(.template)
                        .padding(.leading, 16)
                        .foregroundColor(iconPrimary)
                        .offset(y: -14)
                    VStack(alignment: .leading) {
                        Text(address.fullName)
                            .font(.body)
                            .foregroundColor(textColor)
                        Text(address.streetAddress)
                            .font(.subheadline)
                            .foregroundColor(customLightGray)
                        Text(address.addressCityStateZipcode)
                            .font(.subheadline)
                            .foregroundColor(customLightGray)
                    }
                    Spacer()
                }
            }
            .padding()
            Spacer().frame(height: 0)
            Divider().frame(height: 1)
        }
        .listRowInsets(EdgeInsets())
        .buttonStyle(AddressButtonStyle(theme: themeVal.theme))
        .listRowSeparator(.hidden)
        .onAppear {
            applyTheme(theme: themeVal.theme)
        }
        .onChange(of: themeVal) { newThemeValue in
            applyTheme(theme: newThemeValue.theme)
        }
    }

    // MARK: - Theme Application

    /// Applies the theme to the view.
    /// - Parameter theme: The theme to be applied.
    func applyTheme(theme: Theme) {
        let color = theme.colors
        textColor = Color(color.textPrimary)
        customLightGray = Color(color.textSecondary)
        iconPrimary = Color(color.iconPrimary)
    }
}

// MARK: - CustomButtonStyle

/// A address button style with a specific theme.
struct AddressButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(theme.colors.layer1) : Color(theme.colors.layer2))
            .foregroundColor(.white)
    }
}
