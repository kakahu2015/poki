use crate::device::{Device, Pairing};
use idevice::lockdown::LockdownClient;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{net::IpAddr, path::Path, time::Duration};

#[derive(Deserialize)]
struct Phone {
    device_address: String,
    pairing_file: String,
    #[serde(default)]
    host_name: Option<String>,
}

pub struct Failure {
    pub message: String,
    pub code: &'static str,
}

impl From<crate::device::Failure> for Failure {
    fn from(error: crate::device::Failure) -> Self {
        let message = match error.fix {
            Some(fix) => format!("{} {}", error.detail, fix),
            None => error.detail,
        };
        Self { message, code: error.code.unwrap_or("device") }
    }
}

impl From<idevice::IdeviceError> for Failure {
    fn from(error: idevice::IdeviceError) -> Self {
        Self { message: error.to_string(), code: "device" }
    }
}

fn invalid(message: impl Into<String>) -> Failure {
    Failure { message: message.into(), code: "config" }
}

pub async fn udid(request: Value) -> Result<Value, Failure> {
    let phone: Phone = serde_json::from_value(request).map_err(|error| invalid(error.to_string()))?;
    let address: IpAddr = phone.device_address.parse().map_err(|_| invalid(format!("{} is not an address", phone.device_address)))?;
    let mut pairing = Pairing::read(Path::new(&phone.pairing_file), phone.host_name.as_deref())?;
    let mut device = Device::open(address, &mut pairing, Duration::from_secs(20)).await?;
    let mut lockdown: LockdownClient = device.connect().await?;
    let value = lockdown.get_value(Some("UniqueDeviceID"), None).await?;
    let udid = value.as_string().filter(|value| !value.is_empty()).ok_or_else(|| invalid("the phone did not say its UDID"))?;
    Ok(json!({"udid": udid}))
}
