module umbasa.net/seraph/file-provider-smb

go 1.26.5

require (
	github.com/hirochachacha/go-smb2 v1.1.0
	github.com/spf13/viper v1.21.0
	go.uber.org/fx v1.24.0
	golang.org/x/net v0.57.0
)

require (
	github.com/fsnotify/fsnotify v1.10.1 // indirect
	github.com/geoffgarside/ber v1.2.0 // indirect
	github.com/go-viper/mapstructure/v2 v2.5.0 // indirect
	github.com/pelletier/go-toml/v2 v2.4.3 // indirect
	github.com/rogpeppe/go-internal v1.13.1 // indirect
	github.com/sagikazarmark/locafero v0.12.0 // indirect
	github.com/spf13/afero v1.15.0 // indirect
	github.com/spf13/cast v1.10.0 // indirect
	github.com/spf13/pflag v1.0.10 // indirect
	github.com/subosito/gotenv v1.6.0 // indirect
	go.uber.org/dig v1.19.0 // indirect
	go.uber.org/multierr v1.11.0 // indirect
	go.uber.org/zap v1.28.0 // indirect
	go.yaml.in/yaml/v3 v3.0.5 // indirect
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.40.0 // indirect
)

replace github.com/hirochachacha/go-smb2 => ../vendor-forks/go-smb2
