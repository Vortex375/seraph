import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { AppComponent } from './app.component';

describe('AppComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AppComponent],
      providers: [provideHttpClient(), provideHttpClientTesting()],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('renders the WebDAV password page', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('h1')?.textContent).toContain('Seraph');
    expect(compiled.querySelector('h2')?.textContent).toContain('Set WebDAV Password');
  });

  it('clears the password with a fresh nonce', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.componentInstance.deletePassword();

    httpMock.expectOne({ method: 'GET', url: '/auth/password' }).flush({ nonce: 'n1' });
    const del = httpMock.expectOne(req => req.method === 'DELETE' && req.url === '/auth/password');
    expect(del.request.params.get('nonce')).toBe('n1');
    del.flush(null);
  });
});
