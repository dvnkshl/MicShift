import AppKit

@MainActor
final class StatusMenuHeaderView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let currentCaptionLabel = NSTextField(labelWithString: "Current input")
    private let currentInputLabel = NSTextField(labelWithString: "")
    private let currentCheck = NSImageView()
    private let batteryCaptionLabel = NSTextField(labelWithString: "Battery")
    private let batteryLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        iconView.contentTintColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        currentCaptionLabel.font = .systemFont(ofSize: 11)
        currentCaptionLabel.textColor = .secondaryLabelColor
        currentInputLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        currentInputLabel.lineBreakMode = .byTruncatingTail

        currentCheck.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "Current macOS input"
        )
        currentCheck.contentTintColor = .labelColor
        currentCheck.symbolConfiguration = .init(pointSize: 11, weight: .semibold)

        batteryCaptionLabel.font = .systemFont(ofSize: 11)
        batteryCaptionLabel.textColor = .secondaryLabelColor
        batteryLabel.font = .systemFont(ofSize: 11)
        batteryLabel.textColor = .secondaryLabelColor
        batteryLabel.alignment = .right

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for view in [iconView, titleLabel, subtitleLabel, currentCaptionLabel,
                     currentInputLabel, currentCheck, batteryCaptionLabel, batteryLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(separator)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 400),
            heightAnchor.constraint(equalToConstant: 146),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 66),

            currentCaptionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            currentCaptionLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),

            currentInputLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            currentInputLabel.trailingAnchor.constraint(lessThanOrEqualTo: currentCheck.leadingAnchor, constant: -8),
            currentInputLabel.topAnchor.constraint(equalTo: currentCaptionLabel.bottomAnchor, constant: 3),

            currentCheck.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            currentCheck.centerYAnchor.constraint(equalTo: currentInputLabel.centerYAnchor),
            currentCheck.widthAnchor.constraint(equalToConstant: 14),
            currentCheck.heightAnchor.constraint(equalToConstant: 14),

            batteryCaptionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            batteryCaptionLabel.topAnchor.constraint(equalTo: currentInputLabel.bottomAnchor, constant: 11),

            batteryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            batteryLabel.centerYAnchor.constraint(equalTo: batteryCaptionLabel.centerYAnchor),
            batteryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: batteryCaptionLabel.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        icon: NSImage?,
        title: String,
        subtitle: String,
        currentInput: String,
        battery: String
    ) {
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        currentInputLabel.stringValue = currentInput
        batteryLabel.stringValue = battery
    }
}
