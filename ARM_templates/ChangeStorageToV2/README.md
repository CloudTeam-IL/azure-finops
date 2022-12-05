<h3 align="center">Change Storage Accounts to V2 </h3>

<p align="center">  This script gather all the V1 storage accounts and convert them to V2
    <br> 
</p>

## 📝 Table of Contents

- [Getting Started](#getting_started)
- [Usage](#usage)

## 🏁 Getting Started <a name = "getting_started"></a>

### Prerequisites

Before running the script please install the module az.resourcegraph in cloud shell

```
install-module az.resourcegraph
```

### Installing

To install the script, please open cloud shell and drag the screipt inside

## 🎈 Usage <a name="usage"></a>

To run the script, write the next command in cloud shell

```
./ChangeStorageToV2.ps1
```

Incase you want to exclude specific storage accounts using a tag, write the next command instead

```
./ChangeStorageToV2.ps1 -key <"Your tag's key"> -value <"your tag's value">
```
