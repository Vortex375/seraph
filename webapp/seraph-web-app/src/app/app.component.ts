import { Component, ElementRef, ViewChild } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { PasswordService } from './password.service';
import { FormsModule } from '@angular/forms';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, FormsModule],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css'
})
export class AppComponent {
  
  password: string = ''
  nonce: string = ''

  @ViewChild('pwForm')
  pwForm: ElementRef<HTMLFormElement> | undefined

  constructor(private passwordService: PasswordService) {}

  changePassword() {
    this.passwordService.getNonce().subscribe(nonce => {
      this.nonce = nonce
      setTimeout(() => this.pwForm?.nativeElement?.submit())
    })
  }

  deletePassword() {
    this.passwordService.getNonce().subscribe(nonce => {
      this.passwordService.deletePassword(nonce).subscribe()
    })
  }
}
